// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

interface IExchangeToken {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title MakoOutcomeExchangeV1
/// @notice Mako Market's own outcome markets: orders are signed and matched off chain by a registered operator key,
/// and settled here against cash and shares held in this contract. Nothing is escrowed per order.
///
/// @dev Specified by `.claude/design/OFFCHAIN_MATCHING_PLAN.md` r31 draft 7 (sections 3, 4) on top of
/// `MAKO_POOLS_PLAN.md` r20 section 9.1 (markets, ledger, profit hold, resolution). The S1 spike
/// (`.claude/s1-spike/src/SpikeSettle.sol`) was the reference for the settlement path and its storage rules.
///
/// The registered order signer (`setOrderSigner`, `orderSigner`, checker step 1b, `_boundedIsOwner`, plan section 4.5)
/// is included: the S1 decision record (`S1_SPIKE_RESULTS.md` section 5, 2026-11-22) says the locked fallback fired
/// (rule 1 not met with Safe parties, the registered re-measurement met). Ported from the S1 spike unchanged.
///
/// STORAGE RULES FOR GAS (plan section 3.1 "Settlement gas cannot be raised between estimate and inclusion", r31 d5,
/// d6). Nothing a party or a third party does between the settler's estimate and inclusion may make `matchOrders`
/// dearer, because Monad charges the gas limit:
///   1. Every per-account amount the settlement credits or debits (free cash, shares, the per-market record) is
///      stored as `amount + 1` once first used (0 means never used), so such a slot never returns to zero.
///      Getters report the true amount.
///   2. No storage read or write in the settlement path is skipped or added because of a party-controlled value
///      (balances, net, profit hold, shares, market totals): each write happens on every path.
///   3. Each market slot the settlement writes holds a marker byte set non-zero at creation and never cleared.
/// `test/MakoOutcomeExchangeV1GasMonotone.t.sol` hunts for anything these rules miss.
contract MakoOutcomeExchangeV1 is EIP712 {
    // ------------------------------------------------------------------------------------------------ constants
    uint256 internal constant SHARE = 1_000_000;
    /// @dev Sizes, fills and share amounts are multiples of this (0.01 share), so cash amounts are exact cents.
    uint256 internal constant LOT = 10_000;
    uint256 public constant MAX_FEE_RATE = 700;
    uint256 internal constant MAX_OPTIONS = 11;
    /// @notice Plan section 1 and 4.4 step 2: the most makers one call settles.
    uint256 public constant MAX_MAKERS = 10;
    /// @notice Plan section 4.2 step 0: the longest signature the checker accepts, three 65-byte owner signatures.
    uint256 public constant MAX_SIG_LEN = 195;
    /// @notice Plan section 4.2 step 2: the gas every EIP-1271 call receives, exactly.
    uint256 public constant SIG_GAS = 100_000;
    /// @dev The staticcall's own cost after `maker.code.length` has warmed the account: warm access, memory for at
    /// most 0x64 + 224 bytes of arguments, stack work. Part of the section 4.2 reserve.
    uint256 internal constant CALL_OVERHEAD = 2_000;
    uint256 public constant VETO_PERIOD = 24 hours;
    uint256 public constant BACKSTOP_DELAY = 7 days;
    /// @notice The proposed outcome that unwinds a market at each wallet's net contribution.
    uint8 public constant UNWIND = 255;

    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "Order(uint256 salt,address maker,uint256 marketId,uint8 option,bool isBuy,uint8 price,uint128 size,uint64 expiration,uint64 nonce)"
    );

    uint8 internal constant ST_OPEN = 1;
    uint8 internal constant ST_FINAL = 2;
    uint8 internal constant ST_UNWOUND = 3;

    uint8 internal constant K_DIRECT = 0;
    uint8 internal constant K_MINT = 1;
    uint8 internal constant K_MERGE = 2;

    // ------------------------------------------------------------------------------------------------ types
    /// @dev Plan section 4.1: a static nine-field tuple. The signature is never a field; it travels beside the order.
    struct Order {
        uint256 salt;
        address maker;
        uint256 marketId;
        uint8 option;
        bool isBuy;
        uint8 price;
        uint128 size;
        uint64 expiration;
        uint64 nonce;
    }

    /// @dev One slot per order hash.
    struct OrderState {
        uint128 filled;
        bool cancelled;
    }

    /// @dev What `marketOf` returns.
    struct Market {
        uint8 nOptions;
        uint16 feeRate;
        uint8 status;
        bool hasProposal;
        uint8 proposedOutcome;
        uint8 finalOutcome;
        uint64 tradingClose;
        uint64 resolutionDeadline;
        uint64 finalizableAt;
        uint128 positionCap;
        uint128 setsOutstanding;
        uint128 collateral;
        uint128 feesHeld;
        uint128 profitHeldTotal;
        uint128 unwindPool;
        bytes32 evidenceHash;
        bytes32 rulesHash;
    }

    /// @dev Storage layout of a market. It packs the two slots that settlement writes with a non-zero marker byte each
    /// (`markA`, `markB`, set at creation and never cleared), so neither is ever zero while the market trades,
    /// whatever third parties mint, merge or redeem. `feesHeld` and `unwindPool` are 120 bits (1.3e36).
    struct MarketS {
        uint8 nOptions;
        uint16 feeRate;
        uint8 status;
        bool hasProposal;
        uint8 proposedOutcome;
        uint8 finalOutcome;
        uint64 tradingClose;
        uint64 resolutionDeadline;
        uint64 finalizableAt;
        uint128 positionCap;
        uint128 setsOutstanding;
        uint128 collateral;
        uint120 feesHeld;
        uint8 markA;
        uint128 profitHeldTotal;
        uint120 unwindPool;
        uint8 markB;
        bytes32 evidenceHash;
        bytes32 rulesHash;
    }

    /// @dev Per (market, wallet): `net` is the wallet's net USDC contribution plus one once touched (sentinel), and
    /// `profitHeld` is profit it may not withdraw before finalization (MAKO_POOLS_PLAN section 6).
    struct NetRec {
        uint128 net;
        uint128 profitHeld;
    }

    // ------------------------------------------------------------------------------------------------ storage
    IExchangeToken public immutable USDC;
    address public immutable TREASURY;

    address public admin;
    address public pendingAdmin;
    address public resolver;
    bool public paused;
    uint256 public marketCount;
    uint256 public treasuryBalance;
    uint256 private _lock = 1;

    mapping(uint256 => MarketS) internal _markets;
    mapping(address => uint256) internal _cash; // amount + 1
    mapping(bytes32 => uint256) internal _sharesS; // key(market, option, wallet), amount + 1
    mapping(bytes32 => NetRec) internal _rec; // key(market, wallet)
    mapping(bytes32 => OrderState) public orders;
    mapping(address => uint256) public nonces;
    /// @notice Plan section 4.5: the one key whose plain ECDSA order signatures count for an account while that key is
    /// still an owner of the account (checked by `_boundedIsOwner` at every check).
    mapping(address => address) public orderSigner;
    mapping(address => bool) public isOperator;

    // ------------------------------------------------------------------------------------------------ events
    event MarketCreated(
        uint256 indexed marketId, uint8 nOptions, uint16 feeRate, uint64 tradingClose, uint64 resolutionDeadline
    );
    event Deposited(address indexed wallet, uint256 amount);
    event Withdrawn(address indexed wallet, uint256 amount);
    /// @dev One per maker leg. `fee` is the taker fee on this leaf (direct) or 0 (set kinds, whose taker leaf is
    /// `TakerLeaf`). `toFree` and `toHold` are the split of the one seller paid on this leaf: the taker in a direct
    /// taker sell, the maker in a maker sell; 0 and 0 when the maker buys in a mint.
    event Leaf(
        uint256 indexed marketId,
        bytes32 indexed takerHash,
        bytes32 indexed makerHash,
        uint8 kind,
        uint8 option,
        uint8 price,
        uint256 size,
        uint256 fee,
        uint256 toFree,
        uint256 toHold
    );
    /// @dev The taker's one leaf in a mint or merge, at its effective price `100 - sum of maker prices`.
    event TakerLeaf(
        uint256 indexed marketId,
        bytes32 indexed takerHash,
        uint8 kind,
        uint8 option,
        uint8 price,
        uint256 size,
        uint256 fee,
        uint256 toFree,
        uint256 toHold
    );
    event Cancelled(bytes32 indexed orderHash, address indexed maker);
    event NonceIncremented(address indexed account, uint256 nonce);
    event OperatorSet(address indexed account, bool enabled);
    event OrderSignerSet(address indexed account, address indexed signer);
    event ResolverSet(address indexed resolver);
    event AdminTransferStarted(address indexed pendingAdmin);
    event AdminTransferred(address indexed admin);
    event PausedSet(bool paused);
    event TradingClosedEarly(uint256 indexed marketId, uint64 tradingClose);
    event SetsMinted(uint256 indexed marketId, address indexed wallet, uint256 n);
    event SetsMerged(uint256 indexed marketId, address indexed wallet, uint256 n, uint256 toFree, uint256 toHold);
    event OutcomeProposed(uint256 indexed marketId, uint8 outcome, uint64 finalizableAt, bytes32 evidenceHash);
    event Finalized(uint256 indexed marketId, uint8 outcome);
    event Redeemed(uint256 indexed marketId, address indexed wallet, uint256 shares, uint256 released, uint256 refund);
    event TreasuryWithdrawn(address indexed to, uint256 amount);

    // ------------------------------------------------------------------------------------------------ errors
    // Market-wide or contract-wide (plan section 3.1)
    error NotOperator();
    error Paused();
    error TradingClosed();
    error InsufficientGas();
    // Order-specific, carrying the order's hash (bytes32(0) when raised outside matchOrders)
    error BadSignature(bytes32 orderHash);
    error NonceMismatch(bytes32 orderHash);
    error OrderCancelled(bytes32 orderHash);
    error Expired(bytes32 orderHash);
    error Overfill(bytes32 orderHash);
    error InsufficientCash(bytes32 orderHash);
    error InsufficientShares(bytes32 orderHash);
    error PositionCap(bytes32 orderHash);
    error PartyRefused(bytes32 orderHash);
    error BadSignatureLength(bytes32 orderHash);
    error BadOrderField(bytes32 orderHash);
    error MarketMismatch(bytes32 orderHash);
    // About the match itself
    error SelfMatch();
    error PriceNotCrossed();
    error WrongKind();
    error BadMakerCount();
    error LengthMismatch();
    error FillMismatch();
    error SetPriceSum();
    // Roles, markets, resolution, money (MAKO_POOLS_PLAN section 9.1)
    error NotAdmin();
    error NotAdminOrResolver();
    error NotMaker();
    error NotTreasury();
    error NothingOwed();
    error RoleConflict();
    error TradingOpen();
    error BadOption();
    error BadSize();
    error BadMarket();
    error BadFee();
    error ProposalTooLate();
    error ProposalPending();
    error NoProposal();
    error VetoRunning();
    error VetoElapsed();
    error BackstopNotOpen();
    error NotSettled();
    error TransferFailed();
    error InexactTransfer(uint256 expected, uint256 actual);
    error Reentrancy();

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    /// @param usdc The USDC token. @param treasury The only address fees can ever be sent to.
    /// The deployer is the first admin and the first resolver; it can split the roles with `setResolver` and
    /// `transferAdmin`.
    constructor(address usdc, address treasury) EIP712("Mako Market Exchange", "1") {
        USDC = IExchangeToken(usdc);
        TREASURY = treasury;
        admin = msg.sender;
        resolver = msg.sender;
    }

    // ------------------------------------------------------------------------------------------------ keys
    function _pk(uint256 m, uint256 option, address w) internal pure returns (bytes32) {
        return keccak256(abi.encode(m, option, w));
    }

    function _wk(uint256 m, address w) internal pure returns (bytes32) {
        return keccak256(abi.encode(m, w));
    }

    // ------------------------------------------------------------------------------------------------ admin and roles
    /// @notice Admin only, not while paused. Options 2 to 11, the last is Other. No setter for any term afterwards.
    function createMarket(
        uint8 nOptions,
        uint16 feeRate,
        uint64 tradingClose,
        uint64 resolutionDeadline,
        uint128 positionCap,
        bytes32 rulesHash
    ) external returns (uint256 m) {
        if (msg.sender != admin) revert NotAdmin();
        if (paused) revert Paused();
        if (nOptions < 2 || nOptions > MAX_OPTIONS) revert BadOption();
        if (feeRate > MAX_FEE_RATE) revert BadFee();
        if (tradingClose <= block.timestamp || resolutionDeadline < tradingClose || positionCap == 0) {
            revert BadMarket();
        }
        m = ++marketCount;
        MarketS storage mk = _markets[m];
        mk.nOptions = nOptions;
        mk.feeRate = feeRate;
        mk.status = ST_OPEN;
        mk.tradingClose = tradingClose;
        mk.resolutionDeadline = resolutionDeadline;
        mk.positionCap = positionCap;
        mk.rulesHash = rulesHash;
        mk.markA = 1; // never cleared
        mk.markB = 1;
        emit MarketCreated(m, nOptions, feeRate, tradingClose, resolutionDeadline);
    }

    /// @notice Admin only. Stops `matchOrders`, `mintSets` and new markets. Everything else keeps working.
    function setPaused(bool p) external {
        if (msg.sender != admin) revert NotAdmin();
        paused = p;
        emit PausedSet(p);
    }

    /// @notice Admin only. Adding reverts for the admin, the pending admin, the resolver and `TREASURY`; in turn
    /// `setResolver` and `transferAdmin` revert for an operator, so an operator key never holds a second role (O8).
    function setOperator(address a, bool enabled) external {
        if (msg.sender != admin) revert NotAdmin();
        if (enabled && (a == admin || a == pendingAdmin || a == resolver || a == TREASURY)) revert RoleConflict();
        isOperator[a] = enabled;
        emit OperatorSet(a, enabled);
    }

    function setResolver(address r) external {
        if (msg.sender != admin) revert NotAdmin();
        if (isOperator[r]) revert RoleConflict();
        resolver = r;
        emit ResolverSet(r);
    }

    function transferAdmin(address a) external {
        if (msg.sender != admin) revert NotAdmin();
        if (isOperator[a]) revert RoleConflict();
        pendingAdmin = a;
        emit AdminTransferStarted(a);
    }

    function acceptAdmin() external {
        // nobody can accept when none is pending (the zero address would otherwise equal the cleared slot)
        if (pendingAdmin == address(0) || msg.sender != pendingAdmin) revert NotAdmin();
        admin = msg.sender;
        pendingAdmin = address(0);
        emit AdminTransferred(msg.sender);
    }

    /// @dev Plan section 3.1 "name clash": the caller of `closeEarly` and `proposeOutcome` is the admin or the
    /// resolver. The matching operator (`isOperator`) is a different role and cannot call them.
    function _onlyAdminOrResolver() internal view {
        if (msg.sender != admin && msg.sender != resolver) revert NotAdminOrResolver();
    }

    /// @notice Admin or resolver. Moves `tradingClose` forward to now, never later.
    function closeEarly(uint256 m) external {
        _onlyAdminOrResolver();
        MarketS storage mk = _markets[m];
        if (mk.status != ST_OPEN) revert BadMarket();
        if (block.timestamp < mk.tradingClose) {
            mk.tradingClose = uint64(block.timestamp);
            emit TradingClosedEarly(m, uint64(block.timestamp));
        }
    }

    /// @notice `TREASURY` only, and to `TREASURY` only.
    function withdrawTreasury() external nonReentrant {
        if (msg.sender != TREASURY) revert NotTreasury();
        uint256 amount = treasuryBalance;
        if (amount == 0) revert NothingOwed();
        treasuryBalance = 0;
        _safeTransferOut(TREASURY, amount);
        emit TreasuryWithdrawn(TREASURY, amount);
    }

    // ------------------------------------------------------------------------------------------------ cash
    function deposit(uint256 amount) external nonReentrant {
        uint256 before = USDC.balanceOf(address(this));
        _safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = USDC.balanceOf(address(this)) - before;
        if (received != amount) revert InexactTransfer(amount, received);
        _setCash(msg.sender, cash(msg.sender) + amount);
        emit Deposited(msg.sender, amount);
    }

    /// @notice Never pausable.
    function withdraw(uint256 amount) external nonReentrant {
        uint256 c = cash(msg.sender);
        if (c < amount) revert InsufficientCash(bytes32(0));
        unchecked {
            _setCash(msg.sender, c - amount);
        }
        _safeTransferOut(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function _safeTransferFrom(address from, address to, uint256 amount) private {
        (bool ok, bytes memory data) =
            address(USDC).call(abi.encodeCall(IExchangeToken.transferFrom, (from, to, amount)));
        if (!ok) revert TransferFailed();
        if (data.length != 0 && (data.length != 32 || !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _safeTransferOut(address to, uint256 amount) private {
        uint256 before = USDC.balanceOf(address(this));
        (bool ok, bytes memory data) = address(USDC).call(abi.encodeCall(IExchangeToken.transfer, (to, amount)));
        if (!ok) revert TransferFailed();
        if (data.length != 0 && (data.length != 32 || !abi.decode(data, (bool)))) revert TransferFailed();
        uint256 sent = before - USDC.balanceOf(address(this));
        if (sent != amount) revert InexactTransfer(amount, sent);
    }

    // ------------------------------------------------------------------------------------------------ complete sets
    /// @notice Trading open, not paused. Costs `n` cash, creates `n` of every option.
    function mintSets(uint256 m, uint256 n) external {
        MarketS storage mk = _markets[m];
        if (mk.status != ST_OPEN) revert BadMarket();
        if (paused) revert Paused();
        if (block.timestamp >= mk.tradingClose) revert TradingClosed();
        if (n == 0 || n % LOT != 0) revert BadSize();
        _debit(msg.sender, n, bytes32(0));
        uint256 cap = mk.positionCap;
        uint256 nOpt = mk.nOptions;
        for (uint256 i; i < nOpt; ++i) {
            bytes32 k = _pk(m, i, msg.sender);
            uint256 s = _sharesOf(k) + n;
            if (s > cap) revert PositionCap(bytes32(0));
            _setShares(k, s);
        }
        mk.collateral += uint128(n);
        mk.setsOutstanding += uint128(n);
        _payIn(m, msg.sender, n);
        emit SetsMinted(m, msg.sender, n);
    }

    /// @notice Until finalization, including while paused. The receipt is split by the profit hold.
    function mergeSets(uint256 m, uint256 n) external {
        MarketS storage mk = _markets[m];
        if (mk.status != ST_OPEN) revert BadMarket();
        if (n == 0 || n % LOT != 0) revert BadSize();
        uint256 nOpt = mk.nOptions;
        for (uint256 i; i < nOpt; ++i) {
            bytes32 k = _pk(m, i, msg.sender);
            uint256 s = _sharesOf(k);
            if (s < n) revert InsufficientShares(bytes32(0));
            _setShares(k, s - n);
        }
        mk.collateral -= uint128(n);
        mk.setsOutstanding -= uint128(n);
        (uint256 toFree, uint256 toHold) = _receive(m, msg.sender, n);
        emit SetsMerged(m, msg.sender, n, toFree, toHold);
    }

    // ------------------------------------------------------------------------------------------------ cancel, nonce
    /// @notice Each order's `maker` only. Takes no signature: the caller is the maker (plan section 3.1).
    function cancelOrders(Order[] calldata os) external {
        for (uint256 i; i < os.length; ++i) {
            if (os[i].maker != msg.sender) revert NotMaker();
            bytes32 h = _hashOrder(os[i]);
            orders[h].cancelled = true;
            emit Cancelled(h, msg.sender);
        }
    }

    /// @notice Every signed order of the caller with an older nonce can never fill.
    function incrementNonce() external {
        uint256 n = ++nonces[msg.sender];
        emit NonceIncremented(msg.sender, n);
    }

    /// @notice Plan section 4.5: any account, for itself; never pausable, so an account can always revoke; the zero
    /// address revokes; emits on every call. Replacing or revoking a key voids every order that key signed for the
    /// account (they are re-signed). A plain EOA's registration never validates anything (the owner check needs code);
    /// an EOA with an EIP-7702 delegation has code, so its delegate's `isOwner` runs under `SIG_GAS` (Mako's intake
    /// never books that form: such a maker must pass step 1, plan section 4.6).
    function setOrderSigner(address signer) external {
        orderSigner[msg.sender] = signer;
        emit OrderSignerSet(msg.sender, signer);
    }

    // ------------------------------------------------------------------------------------------------ signatures
    /// @dev Plan section 4.1. No function other than the three of section 4.4 takes an `Order`, so this is internal.
    function _hashOrder(Order calldata o) internal view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(ORDER_TYPEHASH, o)));
    }

    /// @notice The operator's intake runs the contract's own check with the same gas bound (plan section 3.1, r4, r7).
    function isValidOrderSignature(Order calldata o, bytes calldata sig) external view returns (bool) {
        return _checkOrderSig(o.maker, _hashOrder(o), sig);
    }

    /// @dev The shared checker (plan section 4.4), called by `matchOrders` for every party and by
    /// `isValidOrderSignature`. Step 0 length, step 1 ECDSA, step 1b registered signer, step 2 bounded EIP-1271, which
    /// only a signature that recovers no key reaches (a Safe's `v + 4` form, a contract signature).
    function _checkOrderSig(address maker, bytes32 orderHash, bytes calldata sig) internal view returns (bool) {
        if (sig.length == 0 || sig.length > MAX_SIG_LEN) revert BadSignatureLength(orderHash); // before any copy or call
        bytes memory s = sig; // at most 195 bytes
        (address rec, ECDSA.RecoverError err,) = ECDSA.tryRecover(orderHash, s);
        if (err == ECDSA.RecoverError.NoError) {
            if (rec == maker) return true; // step 1
            // step 1b (plan section 4.5): the one storage read. Final when the recovered key is the registered one, so a
            // failed owner check never falls through to EIP-1271 (a stale key passes by no other route).
            address r = orderSigner[maker];
            if (r != address(0) && rec == r) return maker.code.length != 0 && _boundedIsOwner(maker, r);
            // A signature that recovers a key is decided by steps 1 and 1b alone, never by EIP-1271. Otherwise the same
            // bytes, accepted through 1b at the settler's check, could pass step 2 at more gas when sent: the Safe adds
            // the address they recover over its message hash as an owner, then changes or revokes its registration
            // (adversary pass on c7b6135; plan 4.6 "the check fails rather than costing more").
            return false;
        }
        if (maker.code.length == 0) return false;
        return _bounded1271(maker, orderHash, s); // step 2
    }

    /// @dev OpenZeppelin v5.7.0 `SignatureChecker.isValidERC1271SignatureNow`'s assembly with `gas()` replaced by
    /// `SIG_GAS` (plan section 4.2). The output is the constant 32-byte scratch word at 0x00: whatever the maker
    /// returns, at most one word reaches this contract's memory, and there is no `returndatacopy`.
    function _bounded1271(address maker, bytes32 orderHash, bytes memory sig) internal view returns (bool valid) {
        // EIP-150 passes only 63/64 of what is left: with less than this a valid signature could look invalid and
        // blame the maker, so the whole call reverts instead.
        if (gasleft() < SIG_GAS + SIG_GAS / 63 + CALL_OVERHEAD) revert InsufficientGas();
        uint256 gasLimit = SIG_GAS;
        assembly ("memory-safe") {
            let sigLen := mload(sig)
            let ptr := mload(0x40)
            mstore(ptr, shl(224, 0x1626ba7e))
            mstore(add(ptr, 0x04), orderHash)
            mstore(add(ptr, 0x24), 0x40)
            mcopy(add(ptr, 0x44), sig, add(sigLen, 0x20))
            mstore(add(add(ptr, 0x64), sigLen), 0)
            let ok := staticcall(gasLimit, maker, ptr, add(and(add(sigLen, 0x1f), not(0x1f)), 0x64), 0x00, 0x20)
            valid := and(ok, and(gt(returndatasize(), 0x1f), eq(mload(0x00), shl(224, 0x1626ba7e))))
        }
    }

    /// @dev Plan section 4.5: the block above with `isOwner(address)` (0x2f54bf6e) and the key as the call, accepted only
    /// if the call succeeded, returned at least 32 bytes and the word is 1. Same reserve check, `SIG_GAS` and constant
    /// scratch output; no `returndatacopy`.
    function _boundedIsOwner(address maker, address key) internal view returns (bool valid) {
        if (gasleft() < SIG_GAS + SIG_GAS / 63 + CALL_OVERHEAD) revert InsufficientGas();
        uint256 gasLimit = SIG_GAS;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, shl(224, 0x2f54bf6e))
            mstore(add(ptr, 0x04), key)
            let ok := staticcall(gasLimit, maker, ptr, 0x24, 0x00, 0x20)
            valid := and(ok, and(gt(returndatasize(), 0x1f), eq(mload(0x00), 1)))
        }
    }

    // ------------------------------------------------------------------------------------------------ matchOrders
    /// @dev Figures computed once from calldata in step 5, used by step 6.
    struct Plan {
        uint256 m;
        address taker;
        bytes32 tHash;
        uint128 takerFill;
        uint8 nOpt;
        uint8 kind;
        uint8 takerPrice; // set kinds: 100 - sum of maker prices
        uint16 feeRate;
        uint128 cap;
    }

    /// @notice Operator only. Settles one taker against 1 to 10 makers in the taker's market. The kind (direct, mint,
    /// merge) is derived from the orders. Checks run in the order of plan section 4.4; steps 1 to 4 finish before the
    /// first state write. Every failure is a custom error: no input reaches a Solidity panic.
    function matchOrders(
        Order calldata taker,
        bytes calldata takerSig,
        Order[] calldata makers,
        bytes[] calldata makerSigs,
        uint128[] calldata fills,
        uint128 takerFill
    ) external {
        // 1. role and pause
        if (!isOperator[msg.sender]) revert NotOperator();
        if (paused) revert Paused();
        // 2. shape, before any hash, signature or order storage is read
        uint256 n = makers.length;
        if (n == 0 || n > MAX_MAKERS) revert BadMakerCount();
        if (makerSigs.length != n || fills.length != n) revert LengthMismatch();
        // 3. the canonical market (the taker's), then its tradingClose
        Plan memory p;
        p.m = taker.marketId;
        p.taker = taker.maker;
        p.takerFill = takerFill;
        {
            MarketS storage mk = _markets[p.m];
            if (block.timestamp >= mk.tradingClose) revert TradingClosed();
            p.feeRate = mk.feeRate;
            p.cap = mk.positionCap;
            p.nOpt = mk.nOptions;
        }
        // 4. every signature, the taker first, then makers in index order, before any write
        p.tHash = _hashOrder(taker);
        if (!_checkOrderSig(taker.maker, p.tHash, takerSig)) revert BadSignature(p.tHash);
        bytes32[] memory mHash = _checkMakerSigs(makers, makerSigs);
        // 5. match checks that read only calldata and storage this call never writes
        _matchChecks(p, taker, makers, mHash, fills);
        // 6. each party against the state already updated by the earlier parties, then its own writes
        _settleTaker(p, taker, makers, fills);
        for (uint256 i; i < n; ++i) {
            _settleMaker(p, makers[i], mHash[i], fills[i]);
        }
    }

    function _checkMakerSigs(Order[] calldata makers, bytes[] calldata makerSigs)
        internal
        view
        returns (bytes32[] memory mHash)
    {
        uint256 n = makers.length;
        mHash = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            bytes32 h = _hashOrder(makers[i]);
            if (!_checkOrderSig(makers[i].maker, h, makerSigs[i])) revert BadSignature(h);
            mHash[i] = h;
        }
    }

    /// @dev Step 5, in the order of plan section 4.4: MarketMismatch for every maker; BadOrderField for every order;
    /// the kind (WrongKind); the kind's fill rule (FillMismatch); SelfMatch; SetPriceSum; PriceNotCrossed;
    /// PartyRefused. No check reads an order's option, price or size before BadOrderField has range-checked it, and
    /// none reads a fill before the fill rule has.
    function _matchChecks(
        Plan memory p,
        Order calldata taker,
        Order[] calldata makers,
        bytes32[] memory mHash,
        uint128[] calldata fills
    ) internal view {
        uint256 n = makers.length;
        uint256 nOpt = p.nOpt;
        uint256 takerFill = p.takerFill;
        bytes32 tHash = p.tHash;
        // MarketMismatch first, so every option bound below is the canonical market's
        for (uint256 i; i < n; ++i) {
            if (makers[i].marketId != p.m) revert MarketMismatch(mHash[i]);
        }
        // option, tick and lot, taker then makers
        _field(taker, tHash, nOpt);
        for (uint256 i; i < n; ++i) {
            _field(makers[i], mHash[i], nOpt);
        }
        // the kind (section 3.2)
        p.kind = _kind(taker, makers, nOpt);
        // the kind's fill rule; every fill and takerFill nonzero and a lot multiple
        if (takerFill == 0 || takerFill % LOT != 0) revert FillMismatch();
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            uint256 f = fills[i];
            if (f == 0 || f % LOT != 0) revert FillMismatch();
            if (p.kind == K_DIRECT) sum += f;
            else if (f != takerFill) revert FillMismatch();
        }
        if (p.kind == K_DIRECT && sum != takerFill) revert FillMismatch();
        // SelfMatch
        address tw = taker.maker;
        for (uint256 i; i < n; ++i) {
            if (makers[i].maker == tw) revert SelfMatch();
        }
        // prices: SetPriceSum before any subtraction, then PriceNotCrossed
        if (p.kind == K_DIRECT) {
            uint256 lim = taker.price;
            for (uint256 i; i < n; ++i) {
                uint256 mp = makers[i].price;
                if (taker.isBuy ? mp > lim : mp < lim) revert PriceNotCrossed();
            }
        } else {
            uint256 ps;
            for (uint256 i; i < n; ++i) {
                ps += makers[i].price;
            }
            if (ps > 100) revert SetPriceSum();
            uint256 tp = 100 - ps;
            if (p.kind == K_MINT ? tp > taker.price : tp < taker.price) revert PriceNotCrossed();
            p.takerPrice = uint8(tp);
        }
        // PartyRefused: the current operators, admin, resolver and TREASURY (plan section 3.4)
        if (_refused(tw)) revert PartyRefused(tHash);
        for (uint256 i; i < n; ++i) {
            if (_refused(makers[i].maker)) revert PartyRefused(mHash[i]);
        }
    }

    function _field(Order calldata o, bytes32 h, uint256 nOpt) internal pure {
        if (o.price == 0 || o.price > 99 || o.size == 0 || o.size % LOT != 0 || o.option >= nOpt) {
            revert BadOrderField(h);
        }
    }

    /// @dev Direct: every maker on the taker's option and the opposite side. Mint: the taker buys, exactly nOpt - 1
    /// buy makers, one on each other option. Merge: the mirror with sells. Anything else: WrongKind.
    function _kind(Order calldata taker, Order[] calldata makers, uint256 nOpt) internal pure returns (uint8) {
        uint256 n = makers.length;
        uint8 to = taker.option;
        bool tb = taker.isBuy;
        bool direct = true;
        for (uint256 i; i < n; ++i) {
            if (makers[i].option != to || makers[i].isBuy == tb) {
                direct = false;
                break;
            }
        }
        if (direct) return K_DIRECT;
        if (n != nOpt - 1) revert WrongKind();
        uint256 seen = uint256(1) << to;
        for (uint256 i; i < n; ++i) {
            uint256 bit = uint256(1) << makers[i].option;
            if (makers[i].isBuy != tb || seen & bit != 0) revert WrongKind();
            seen |= bit;
        }
        return tb ? K_MINT : K_MERGE;
    }

    /// @dev Plan section 3.4: enforced by code for the CURRENT holders of the four roles, read in this call.
    function _refused(address a) internal view returns (bool) {
        return isOperator[a] || a == admin || a == resolver || a == TREASURY;
    }

    /// @dev Per-party order checks shared by taker and makers (step 6): cancelled, nonce, expiry, overfill.
    function _orderState(Order calldata o, bytes32 h, uint256 fill) internal view returns (OrderState storage st) {
        st = orders[h];
        if (st.cancelled) revert OrderCancelled(h);
        if (o.nonce != nonces[o.maker]) revert NonceMismatch(h);
        if (o.expiration != 0 && block.timestamp > o.expiration) revert Expired(h);
        if (uint256(st.filled) + fill > o.size) revert Overfill(h);
    }

    function _settleTaker(Plan memory p, Order calldata t, Order[] calldata makers, uint128[] calldata fills) internal {
        OrderState storage st = _orderState(t, p.tHash, p.takerFill);
        if (t.isBuy) _takerBuy(p, t, st, _takerPay(p, makers, fills));
        else _takerSell(p, t, st);
    }

    /// @dev Pays every leg's value and fee; receives takerFill shares.
    function _takerBuy(Plan memory p, Order calldata t, OrderState storage st, uint256 pay) internal {
        address w = t.maker;
        uint128 q = p.takerFill;
        bytes32 posKey = _pk(p.m, t.option, w);
        if (cash(w) < pay) revert InsufficientCash(p.tHash);
        uint256 s = _sharesOf(posKey) + q;
        if (s > p.cap) revert PositionCap(p.tHash);
        st.filled += q;
        _setCash(w, cash(w) - pay);
        _setShares(posKey, s);
        _payIn(p.m, w, pay);
        if (p.kind == K_MINT) {
            MarketS storage mk = _markets[p.m];
            mk.collateral += q;
            mk.setsOutstanding += q;
            uint256 fee = _fee(p.feeRate, q, p.takerPrice);
            if (fee != 0) mk.feesHeld += uint120(fee);
            emit TakerLeaf(p.m, p.tHash, K_MINT, t.option, p.takerPrice, q, fee, 0, 0);
        }
    }

    /// @dev Gives takerFill shares. Direct: credited per leaf in `_makerBuy`, so each leaf carries its own split.
    /// Merge: receives `100 - sum of maker prices` per unit net of its fee, through the hold split.
    function _takerSell(Plan memory p, Order calldata t, OrderState storage st) internal {
        address w = t.maker;
        uint128 q = p.takerFill;
        bytes32 posKey = _pk(p.m, t.option, w);
        uint256 s = _sharesOf(posKey);
        if (s < q) revert InsufficientShares(p.tHash);
        st.filled += q;
        _setShares(posKey, s - q);
        if (p.kind == K_DIRECT) return;
        uint256 fee = _fee(p.feeRate, q, p.takerPrice);
        (uint256 tFree, uint256 tHold) = _receive(p.m, w, uint256(q) * p.takerPrice / 100 - fee);
        MarketS storage mk = _markets[p.m];
        mk.collateral -= q;
        mk.setsOutstanding -= q;
        if (fee != 0) mk.feesHeld += uint120(fee);
        emit TakerLeaf(p.m, p.tHash, K_MERGE, t.option, p.takerPrice, q, fee, tFree, tHold);
    }

    /// @dev Everything a buying taker pays across all legs, fees included.
    function _takerPay(Plan memory p, Order[] calldata makers, uint128[] calldata fills)
        internal
        pure
        returns (uint256 pay)
    {
        if (p.kind != K_DIRECT) {
            return uint256(p.takerFill) * p.takerPrice / 100 + _fee(p.feeRate, p.takerFill, p.takerPrice);
        }
        for (uint256 i; i < makers.length; ++i) {
            uint256 f = fills[i];
            uint256 mp = makers[i].price;
            pay += f * mp / 100 + _fee(p.feeRate, f, mp);
        }
    }

    function _settleMaker(Plan memory p, Order calldata o, bytes32 h, uint256 f) internal {
        OrderState storage st = _orderState(o, h, f);
        if (o.isBuy) _makerBuy(p, o, h, st, f);
        else _makerSell(p, o, h, st, f);
    }

    /// @dev A maker buy pays its own price and receives f shares. In a direct match the taker sold to it, so the
    /// taker's receipt for this leaf, net of the taker fee on it, is credited here with its own split.
    function _makerBuy(Plan memory p, Order calldata o, bytes32 h, OrderState storage st, uint256 f) internal {
        uint256 v = f * o.price / 100;
        {
            address w = o.maker;
            bytes32 posKey = _pk(p.m, o.option, w);
            if (cash(w) < v) revert InsufficientCash(h);
            uint256 s = _sharesOf(posKey) + f;
            if (s > p.cap) revert PositionCap(h);
            st.filled += uint128(f);
            _setCash(w, cash(w) - v);
            _setShares(posKey, s);
            _payIn(p.m, w, v);
        }
        uint256 fee;
        uint256 tf;
        uint256 th;
        if (p.kind == K_DIRECT) {
            fee = _fee(p.feeRate, f, o.price);
            (tf, th) = _receive(p.m, p.taker, v - fee);
            if (fee != 0) _markets[p.m].feesHeld += uint120(fee);
        }
        emit Leaf(p.m, p.tHash, h, p.kind, o.option, o.price, f, fee, tf, th);
    }

    /// @dev A maker sell gives f shares and receives its own price through the hold split. In a direct match the taker
    /// bought from it and already paid this leaf's value and fee (`_takerBuy`); the fee is booked here per leaf.
    function _makerSell(Plan memory p, Order calldata o, bytes32 h, OrderState storage st, uint256 f) internal {
        address w = o.maker;
        uint8 mp = o.price;
        bytes32 posKey = _pk(p.m, o.option, w);
        uint256 s = _sharesOf(posKey);
        if (s < f) revert InsufficientShares(h);
        st.filled += uint128(f);
        _setShares(posKey, s - f);
        (uint256 mf, uint256 mh) = _receive(p.m, w, f * mp / 100);
        uint256 fee;
        if (p.kind == K_DIRECT) {
            fee = _fee(p.feeRate, f, mp);
            if (fee != 0) _markets[p.m].feesHeld += uint120(fee);
        }
        emit Leaf(p.m, p.tHash, h, p.kind, o.option, mp, f, fee, mf, mh);
    }

    // ------------------------------------------------------------------------------------------------ resolution
    /// @notice Admin or resolver, after trading closed. A winning option or `UNWIND`. During the 24-hour veto window
    /// the proposal may be replaced (corrected); after it, only `finalize` can act.
    function proposeOutcome(uint256 m, uint8 outcome, bytes32 evidenceHash) external {
        _onlyAdminOrResolver();
        MarketS storage mk = _markets[m];
        if (mk.status != ST_OPEN) revert BadMarket();
        if (block.timestamp < mk.tradingClose) revert TradingOpen();
        if (mk.hasProposal && block.timestamp >= mk.finalizableAt) revert VetoElapsed();
        if (outcome != UNWIND && outcome >= mk.nOptions) revert BadOption();
        uint256 b = uint256(mk.resolutionDeadline) + BACKSTOP_DELAY;
        if (block.timestamp + VETO_PERIOD > b) revert ProposalTooLate();
        uint64 fa = uint64(block.timestamp + VETO_PERIOD);
        mk.hasProposal = true;
        mk.proposedOutcome = outcome;
        mk.finalizableAt = fa;
        mk.evidenceHash = evidenceHash;
        emit OutcomeProposed(m, outcome, fa, evidenceHash);
    }

    /// @notice Anyone, after the veto. A winner releases `feesHeld` to the treasury; an unwind keeps everything in
    /// the pool.
    function finalize(uint256 m) external {
        MarketS storage mk = _markets[m];
        if (mk.status != ST_OPEN) revert BadMarket();
        if (!mk.hasProposal) revert NoProposal();
        if (block.timestamp < mk.finalizableAt) revert VetoRunning();
        uint8 outcome = mk.proposedOutcome;
        mk.finalOutcome = outcome;
        if (outcome == UNWIND) {
            _openUnwind(mk);
        } else {
            mk.status = ST_FINAL;
            uint256 f = mk.feesHeld;
            if (f != 0) {
                mk.feesHeld = 0;
                treasuryBalance += f;
            }
        }
        emit Finalized(m, outcome);
    }

    /// @notice Anyone, from `resolutionDeadline + 7 days`, only if no proposal exists.
    function backstopUnwind(uint256 m) external {
        MarketS storage mk = _markets[m];
        if (mk.status != ST_OPEN) revert BadMarket();
        if (block.timestamp < uint256(mk.resolutionDeadline) + BACKSTOP_DELAY) revert BackstopNotOpen();
        if (mk.hasProposal) revert ProposalPending();
        _openUnwind(mk);
        mk.finalOutcome = UNWIND;
        emit Finalized(m, UNWIND);
    }

    function _openUnwind(MarketS storage mk) internal {
        mk.status = ST_UNWOUND;
        mk.unwindPool = uint120(uint256(mk.collateral) + mk.feesHeld + mk.profitHeldTotal);
        mk.collateral = 0;
        mk.feesHeld = 0;
        mk.profitHeldTotal = 0;
    }

    /// @notice Never pausable. Winner: shares at 1 USDC each plus held profit. Unwind: the wallet's net.
    function redeem(uint256 m) external {
        MarketS storage mk = _markets[m];
        uint8 st = mk.status;
        uint256 sh;
        uint256 released;
        uint256 refund;
        if (st == ST_FINAL) {
            bytes32 k = _pk(m, mk.finalOutcome, msg.sender);
            sh = _sharesOf(k);
            if (sh != 0) {
                _setShares(k, 0);
                mk.collateral -= uint128(sh);
            }
            released = _releaseHeld(m, msg.sender);
        } else if (st == ST_UNWOUND) {
            refund = _unwindRefund(m, msg.sender);
        } else {
            revert NotSettled();
        }
        uint256 pay = sh + released + refund;
        if (pay != 0) _setCash(msg.sender, cash(msg.sender) + pay);
        emit Redeemed(m, msg.sender, sh, released, refund);
    }

    // ------------------------------------------------------------------------------------------------ views
    function marketOf(uint256 m) external view returns (Market memory v) {
        MarketS storage k = _markets[m];
        v = Market({
            nOptions: k.nOptions,
            feeRate: k.feeRate,
            status: k.status,
            hasProposal: k.hasProposal,
            proposedOutcome: k.proposedOutcome,
            finalOutcome: k.finalOutcome,
            tradingClose: k.tradingClose,
            resolutionDeadline: k.resolutionDeadline,
            finalizableAt: k.finalizableAt,
            positionCap: k.positionCap,
            setsOutstanding: k.setsOutstanding,
            collateral: k.collateral,
            feesHeld: k.feesHeld,
            profitHeldTotal: k.profitHeldTotal,
            unwindPool: k.unwindPool,
            evidenceHash: k.evidenceHash,
            rulesHash: k.rulesHash
        });
    }

    function positionOf(uint256 m, uint8 option, address w) external view returns (uint256) {
        return _sharesOf(_pk(m, option, w));
    }

    /// @notice A wallet's net contribution to a market and the profit it holds there.
    function recOf(uint256 m, address w) external view returns (uint256 net, uint256 profitHeld) {
        NetRec storage r = _rec[_wk(m, w)];
        return (_netOf(r), r.profitHeld);
    }

    /// @notice The taker fee of one leaf, `ceil(feeRate x size x t x (100 - t) / 10^8)`, with `t` in 0 to 99.
    function feeOf(uint256 m, uint256 size, uint256 price) external view returns (uint256) {
        if (price > 99 || size > type(uint128).max) revert BadOrderField(bytes32(0));
        return _fee(_markets[m].feeRate, size, price);
    }

    /// @notice How a receipt would be split now, between free cash and held profit.
    function splitOf(uint256 m, address w, uint256 receipt) external view returns (uint256 toFree, uint256 toHold) {
        uint256 net = _netOf(_rec[_wk(m, w)]);
        toFree = receipt <= net ? receipt : net;
        toHold = receipt - toFree;
    }

    function cash(address w) public view returns (uint256) {
        return _dec(_cash[w]);
    }

    // ------------------------------------------------------------------------------------------------ internals
    /// @dev Stored word to amount: 0 means never used, otherwise word - 1.
    function _dec(uint256 raw) internal pure returns (uint256) {
        return raw == 0 ? 0 : raw - 1;
    }

    function _setCash(address w, uint256 v) internal {
        _cash[w] = v + 1;
    }

    function _sharesOf(bytes32 k) internal view returns (uint256) {
        return _dec(_sharesS[k]);
    }

    function _setShares(bytes32 k, uint256 v) internal {
        _sharesS[k] = v + 1;
    }

    function _netOf(NetRec storage r) internal view returns (uint256) {
        return _dec(r.net);
    }

    function _setNet(NetRec storage r, uint256 v) internal {
        r.net = uint128(v + 1);
    }

    function _debit(address w, uint256 amount, bytes32 h) internal {
        uint256 c = cash(w);
        if (c < amount) revert InsufficientCash(h);
        unchecked {
            _setCash(w, c - amount);
        }
    }

    /// @dev ceil(feeRate x size x t x (100 - t) / 1e8), per leaf; t in 0..99, size below 2^128 on every path.
    function _fee(uint256 rate, uint256 size, uint256 t) internal pure returns (uint256) {
        if (rate == 0) return 0;
        uint256 num = rate * size * t * (100 - t);
        return (num + 99_999_999) / 100_000_000;
    }

    function _payIn(uint256 m, address w, uint256 amount) internal {
        NetRec storage r = _rec[_wk(m, w)];
        _setNet(r, uint128(_netOf(r)) + uint128(amount));
    }

    /// @dev A receipt goes to free cash only up to the wallet's current net; the excess is held. Every access below
    /// happens whatever `net` is: a party moving its own net between an estimate and inclusion must not skip or add a
    /// storage access, nor turn a no-change write into a change (rule 2 of the header).
    function _receive(uint256 m, address w, uint256 amount) internal returns (uint256 toFree, uint256 toHold) {
        NetRec storage r = _rec[_wk(m, w)];
        uint256 net = _netOf(r);
        toFree = amount <= net ? amount : net;
        toHold = amount - toFree;
        _setNet(r, net - toFree);
        r.profitHeld += uint128(toHold);
        MarketS storage mk = _markets[m];
        mk.profitHeldTotal += uint128(toHold);
        _setCash(w, cash(w) + toFree);
    }

    function _releaseHeld(uint256 m, address w) internal returns (uint256 released) {
        NetRec storage r = _rec[_wk(m, w)];
        released = r.profitHeld;
        if (released != 0) {
            r.profitHeld = 0;
            _markets[m].profitHeldTotal -= uint128(released);
        }
    }

    function _unwindRefund(uint256 m, address w) internal returns (uint256 refund) {
        NetRec storage r = _rec[_wk(m, w)];
        refund = _netOf(r);
        if (refund != 0 || r.profitHeld != 0) {
            _setNet(r, 0);
            r.profitHeld = 0;
            _markets[m].unwindPool -= uint120(refund);
        }
    }
}
