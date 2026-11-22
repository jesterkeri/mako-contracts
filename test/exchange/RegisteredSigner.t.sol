// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Scene} from "./Scene.sol";
import {SafeExec, ISafeExec, ISafeProxyFactory, ISafeSetup} from "./SafeExec.sol";
import {MakoOutcomeExchangeV1 as X} from "../../src/MakoOutcomeExchangeV1.sol";

/// @notice An `isOwner` answerer with a chosen behaviour, which also registers its own signer (a contract maker needs a
/// function to call `setOrderSigner` from). Ported from the S1 spike's `OwnerStub`.
contract OwnerStub {
    uint256 internal immutable MODE;

    constructor(uint256 mode) {
        MODE = mode;
    }

    function register(X ex, address key) external {
        ex.setOrderSigner(key);
    }

    fallback() external {
        uint256 m = MODE;
        assembly {
            switch m
            // case 0 burns all its gas
            case 0 { for {} 1 {} {} }
            case 1 {
                mstore(0, 0)
                return(0, 6000000)
            } // 6,000,000 bytes, the first word 0
            case 2 {
                mstore(0, 2)
                return(0, 32)
            } // a word that is not 1
            case 3 {
                mstore(0, 1)
                return(1, 31)
            } // 31 bytes: shorter than a word
            case 4 { revert(0, 0) }
            case 5 {
                mstore(0, 1)
                return(0, 32)
            } // owner of everyone
            case 7 {
                mstore(0, 1)
                return(0, 6000000)
            } // 6,000,000 bytes, the first word 1
            case 6 {
                // isOwner says no, but EIP-1271 says yes (a fall-through to step 2 would accept)
                switch shr(224, calldataload(0))
                case 0x1626ba7e {
                    mstore(0, shl(224, 0x1626ba7e))
                    return(0, 32)
                }
                default {
                    mstore(0, 0)
                    return(0, 32)
                }
            }
            default { revert(0, 0) }
        }
    }
}

/// @notice P1r (aj): a contract maker that registers its own key and whose `isOwner(key)` answers true, but first burns
/// about 85,000 gas when `tx.gasprice` is not 0.
contract GasPriceOwner {
    function register(X ex, address key) external {
        ex.setOrderSigner(key);
    }

    function isOwner(address) external view returns (bool) {
        if (tx.gasprice != 0) {
            uint256 stop = gasleft() > 85_000 ? gasleft() - 85_000 : 0;
            while (gasleft() > stop) {}
        }
        return true;
    }
}

/// @notice Plan section 4.5 "Registered order signer" and P1r (ae) to (aj), on the exchange's own harness and real
/// Safe v1.4.1 proxies (the pinned code of `test/vectors/safe-v1.4.1/`, as `Vectors.t.sol` installs it). Ported from the
/// S1 spike's `RegisteredSigner.t.sol`. Gas figures the spike printed are asserted here against the plan's bound:
/// one party costs at most 60,000 gas over an honest one-owner Safe (plan 4.2, 4.5).
contract RegisteredSignerTest is Scene, SafeExec {
    bytes4 internal constant IS_VALID_SIG = 0x1626ba7e;
    bytes4 internal constant IS_OWNER = 0x2f54bf6e;
    bytes32 internal constant SAFE_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(uint256 chainId,address verifyingContract)");
    bytes32 internal constant SAFE_MSG_TYPEHASH = keccak256("SafeMessage(bytes message)");
    /// @dev Plan 4.2, 4.5: the most one party adds to a settlement over an honest one-owner Safe.
    uint256 internal constant PARTY_BOUND = 60_000;

    event OrderSignerSet(address indexed account, address indexed signer);

    uint256 internal saltNonce = 1000;

    function setUp() public override {
        super.setUp();
        if (!_installSafe()) {
            vm.skip(true, "needs chain 31337 (forge's default)");
            return;
        }
    }

    // ------------------------------------------------------------------------------------------------ helpers
    /// @dev A one-owner Safe (Safe4337Module as handler, the email-account shape), owner key `pk`.
    function _safe(string memory name) internal returns (uint256 pk, address owner, address safe) {
        (owner, pk) = makeAddrAndKey(name);
        safe = _safeFor(owner);
    }

    function _safeFor(address owner) internal returns (address safe) {
        address[] memory owners = new address[](1);
        owners[0] = owner;
        bytes memory init = abi.encodeCall(
            ISafeSetup.setup, (owners, 1, address(0), "", SAFE_MODULE, address(0), 0, payable(address(0)))
        );
        safe = ISafeProxyFactory(SAFE_FACTORY).createProxyWithNonce(SAFE_SINGLETON, init, saltNonce++);
    }

    /// @dev The Safe registers `key` through its own execTransaction, sent by `owner`.
    function _register(address safe, address owner, address key) internal returns (uint256 used) {
        used = _safeExec(safe, owner, address(ex), abi.encodeCall(X.setOrderSigner, (key)));
        assertEq(ex.orderSigner(safe), key);
    }

    /// @dev An email Safe's own form: personal_sign of safeMsgHash, v + 4 (plan 4.2).
    function _safeSig(uint256 ownerPk, address safe, bytes32 h) internal view returns (bytes memory) {
        bytes32 domain = keccak256(abi.encode(SAFE_DOMAIN_TYPEHASH, vm.getChainId(), safe));
        bytes32 smh = keccak256(
            abi.encodePacked(
                hex"1901", domain, keccak256(abi.encode(SAFE_MSG_TYPEHASH, keccak256(abi.encodePacked(h))))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(ownerPk, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", smh)));
        return abi.encodePacked(r, s, uint8(v + 4));
    }

    /// @dev Cash for any buy and complete sets (net) for any sell, for a wallet that is not an EOA party of the Scene.
    function _fundAddr(address a, uint256 cashAmt, uint256 sets) internal {
        if (cashAmt != 0) _deposit(a, cashAmt);
        if (sets != 0) _mint(a, m, sets);
    }

    /// @dev A taker `taker` buying and a maker `mk` selling, the two orders.
    function _pair(address taker, address mk) internal returns (X.Order memory to, X.Order memory mo) {
        _fundAddr(taker, 1_000 * SHARE, 0);
        _fundAddr(mk, 0, 100 * SHARE);
        to = _order(taker, m, 0, true, 50, 10 * SHARE);
        mo = _order(mk, m, 0, false, 40, 10 * SHARE);
    }

    function _check(X.Order memory o, bytes memory sig) internal view returns (bool ok) {
        ok = ex.isValidOrderSignature(o, sig);
    }

    /// @dev `isValidOrderSignature` and the gas its whole call used (the checker plus calldata decoding).
    function _checkGas(X.Order memory o, bytes memory sig) internal view returns (bool ok, uint256 used) {
        uint256 g = gasleft();
        ok = ex.isValidOrderSignature(o, sig);
        used = g - gasleft();
    }

    function _expectBad(bytes32 h) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(X.BadSignature.selector, h);
    }

    function _noWrite(bytes memory err, X.Order memory t, bytes memory ts, X.Order memory mo, bytes memory msig)
        internal
    {
        _expectNoWrite(err, _call(t, ts, _one(mo), _oneSig(msig), _oneFill(10 * SHARE), 10 * SHARE));
    }

    function _settlePair(X.Order memory to, bytes memory ts, X.Order memory mo, bytes memory msig) internal {
        _settle(to, ts, _one(mo), _oneSig(msig), _oneFill(10 * SHARE), 10 * SHARE);
    }

    /// @dev The gas of an honest registered one-owner Safe's check, the baseline of the 60,000-gas bound: the Safe's own
    /// `v + 4` step, which is the most an honest email account costs (plan 4.2).
    /// @dev The plan's per-party bound (60,000 over an honest one-owner Safe, plan 4.2, 4.5) was derived and measured on
    /// Monad's gas schedule (cold account 10,100, linear memory price). It is asserted as stated when the run is on that
    /// schedule (`EXPECT_MONAD_GAS=true` with `FOUNDRY_PROFILE=monad`, as the CI step for GasMonotone sets). On Ethereum's
    /// schedule an honest Safe is cheaper, so the excess is larger by construction and the check is the absolute one the
    /// spike made: the whole call stays below `SIG_GAS` + 30,000.
    function _assertPartyBound(uint256 used, uint256 honest, string memory why) internal view {
        if (vm.envOr("EXPECT_MONAD_GAS", false)) {
            assertLe(used, honest + PARTY_BOUND, why);
        } else {
            assertLt(used, ex.SIG_GAS() + 30_000, why);
        }
    }

    function _honestSafeGas() internal returns (uint256 used) {
        (uint256 hk, address hown, address hs) = _safe("honest-baseline");
        _register(hs, hown, hown);
        X.Order memory ho = _order(hs, m, 0, false, 40, 10 * SHARE);
        bool ok;
        (ok, used) = _checkGas(ho, _safeSig(hk, hs, _hash(ho)));
        assertTrue(ok, "the honest Safe's v + 4 signature is accepted");
    }

    // ------------------------------------------------------------------------------------------------ the contract surface (plan 4.5)
    function test_setOrderSigner_writesOnlyCaller_emitsEveryCall_neverPausable() public {
        address a = makeAddr("a");
        address b = makeAddr("b");
        address k = makeAddr("k");
        vm.expectEmit(true, true, false, true);
        emit OrderSignerSet(a, k);
        vm.prank(a);
        ex.setOrderSigner(k);
        assertEq(ex.orderSigner(a), k);
        assertEq(ex.orderSigner(b), address(0));
        // the same value again emits again
        vm.expectEmit(true, true, false, true);
        emit OrderSignerSet(a, k);
        vm.prank(a);
        ex.setOrderSigner(k);
        // never pausable, and zero revokes (emitting too)
        ex.setPaused(true);
        vm.expectEmit(true, true, false, true);
        emit OrderSignerSet(a, address(0));
        vm.prank(a);
        ex.setOrderSigner(address(0));
        assertEq(ex.orderSigner(a), address(0));
    }

    function test_setOrderSigner_selectorsAreThePlans() public view {
        assertEq(X.setOrderSigner.selector, bytes4(0x937832f9));
        assertEq(ex.orderSigner.selector, bytes4(0x585dcd19));
    }

    // ------------------------------------------------------------------------------------------------ (ae)
    function test_P1r_ae_registeredOwnerKey_settles_no1271Frame() public {
        (uint256 tk, address town, address t) = _safe("ae-taker");
        (uint256 mk, address mown, address mm) = _safe("ae-maker");
        _register(t, town, town);
        _register(mm, mown, mown);
        (X.Order memory to, X.Order memory mo) = _pair(t, mm);
        bytes memory msig = _sign(mk, mo);
        assertEq(msig.length, 65);
        // settles with no isValidSignature frame on either Safe, and one isOwner call per party
        vm.expectCall(t, abi.encodeWithSelector(IS_VALID_SIG), 0);
        vm.expectCall(mm, abi.encodeWithSelector(IS_VALID_SIG), 0);
        vm.expectCall(t, abi.encodeWithSelector(IS_OWNER, town), 1);
        vm.expectCall(mm, abi.encodeWithSelector(IS_OWNER, mown), 1);
        _settlePair(to, _sign(tk, to), mo, msig);
        (uint128 filled,) = ex.orders(_hash(mo));
        assertEq(filled, 10 * SHARE);
    }

    function test_P1r_ae_sameSafe_vPlus4_alsoAccepted_registeredStepNoDearer() public {
        (uint256 mk, address mown, address mm) = _safe("ae-both");
        _register(mm, mown, mown);
        X.Order memory mo = _order(mm, m, 0, false, 40, 10 * SHARE);
        bytes32 h = _hash(mo);
        (bool okR, uint256 gasR) = _checkGas(mo, _sign(mk, mo));
        (bool ok4, uint256 gas4) = _checkGas(mo, _safeSig(mk, mm, h));
        assertTrue(okR);
        assertTrue(ok4, "the same Safe's v + 4 signature is accepted, through step 2");
        // plan 9.2 (ae): rule 2's step-2 figures bound the registered path. The v + 4 call ran second (its Safe already
        // warm), so allow one cold-account access (Monad 10,100) between the two measurements
        assertLe(gasR, gas4 + 10_100, "the registered step uses no more gas than the v + 4 step");
        assertLt(gasR, ex.SIG_GAS() + 30_000, "the registered step stays within SIG_GAS plus overhead");
    }

    function test_P1r_ae_safeForm_vPlus4_doesNotTouchIsOwner() public {
        (uint256 mk, address mown, address mm) = _safe("ae-v4");
        _register(mm, mown, mown);
        X.Order memory mo = _order(mm, m, 0, false, 40, 10 * SHARE);
        bytes32 h = _hash(mo);
        vm.expectCall(mm, abi.encodeWithSelector(IS_OWNER), 0);
        assertTrue(_check(mo, _safeSig(mk, mm, h)));
    }

    // ------------------------------------------------------------------------------------------------ (af)
    function test_P1r_af_revoked_isBadSignature_beforeAnyWrite() public {
        (uint256 tk, address town, address t) = _safe("af-taker");
        (uint256 mk, address mown, address mm) = _safe("af-maker");
        _register(t, town, town);
        _register(mm, mown, mown);
        (X.Order memory to, X.Order memory mo) = _pair(t, mm);
        bytes memory ts = _sign(tk, to);
        bytes memory msig = _sign(mk, mo);
        assertTrue(_check(mo, msig));
        vm.expectEmit(true, true, false, true);
        emit OrderSignerSet(mm, address(0));
        _safeExec(mm, mown, address(ex), abi.encodeCall(X.setOrderSigner, (address(0))));
        assertEq(ex.orderSigner(mm), address(0));
        _noWrite(_expectBad(_hash(mo)), to, ts, mo, msig);
    }

    // ------------------------------------------------------------------------------------------------ (ag)
    address internal agT;
    address internal agM;
    address internal agNew;
    uint256 internal agTk;
    uint256 internal agOldPk;
    uint256 internal agNewPk;

    /// @dev A registered maker Safe whose owner is then swapped out of band; the old key stays registered.
    function _swapScenario() internal {
        address town;
        address oldOwner;
        (agTk, town, agT) = _safe("ag-taker");
        (agOldPk, oldOwner, agM) = _safe("ag-old");
        (agNew, agNewPk) = makeAddrAndKey("ag-new");
        _register(agT, town, town);
        _register(agM, oldOwner, oldOwner);
        _fundAddr(agT, 1_000 * SHARE, 0);
        _fundAddr(agM, 0, 100 * SHARE);
        _safeExec(agM, oldOwner, agM, abi.encodeCall(ISafeExec.swapOwner, (address(1), oldOwner, agNew)));
        assertFalse(ISafeExec(agM).isOwner(oldOwner));
        assertEq(ex.orderSigner(agM), oldOwner);
    }

    function test_P1r_ag_swapOwner_staleKey_orderBeforeAndAfterSwap_refused_no1271() public {
        // an order signed with the old key BEFORE the swap (the signature is valid until the swap happens)
        (address oldOwner, uint256 oldPk) = makeAddrAndKey("ag-old0");
        address m0 = _safeFor(oldOwner);
        _register(m0, oldOwner, oldOwner);
        X.Order memory early = _order(m0, m, 0, false, 40, 10 * SHARE);
        bytes memory earlySig = _sign(oldPk, early);
        assertTrue(_check(early, earlySig), "valid before the swap");
        _safeExec(m0, oldOwner, m0, abi.encodeCall(ISafeExec.swapOwner, (address(1), oldOwner, makeAddr("ag-other"))));
        assertFalse(_check(early, earlySig), "refused after the swap");
        // the full scenario, settled through matchOrders
        _swapScenario();
        X.Order memory to = _order(agT, m, 0, true, 50, 10 * SHARE);
        X.Order memory late = _order(agM, m, 0, false, 41, 10 * SHARE);
        vm.expectCall(agM, abi.encodeWithSelector(IS_VALID_SIG), 0);
        _noWrite(_expectBad(_hash(late)), to, _sign(agTk, to), late, _sign(agOldPk, late));
    }

    function test_P1r_ag_newOwner_registersAndSettles() public {
        _swapScenario();
        X.Order memory to = _order(agT, m, 0, true, 50, 10 * SHARE);
        X.Order memory mo = _order(agM, m, 0, false, 41, 10 * SHARE);
        _register(agM, agNew, agNew);
        _settlePair(to, _sign(agTk, to), mo, _sign(agNewPk, mo));
        (uint128 filled,) = ex.orders(_hash(mo));
        assertEq(filled, 10 * SHARE);
    }

    // ------------------------------------------------------------------------------------------------ (ah)
    function test_P1r_ah_strangerWritesOnlyItsOwnEntry() public {
        (, address aown, address a) = _safe("ah-a");
        _register(a, aown, aown);
        address stranger = makeAddr("ah-stranger");
        vm.prank(stranger);
        ex.setOrderSigner(makeAddr("x"));
        assertEq(ex.orderSigner(a), aown);
        assertEq(ex.orderSigner(stranger), makeAddr("x"));
    }

    function test_P1r_ah_keyOfSafeA_cannotSignForSafeB() public {
        (uint256 ak, address aown, address a) = _safe("ahb-a");
        (, address bown, address b) = _safe("ahb-b");
        _register(a, aown, aown);
        _register(b, bown, bown);
        X.Order memory ob = _order(b, m, 0, false, 40, 10 * SHARE);
        assertFalse(_check(ob, _sign(ak, ob)), "A's registered key for B's order");
        // and a key registered to nobody for B
        (, uint256 sk) = makeAddrAndKey("ahb-stray");
        assertFalse(_check(ob, _sign(sk, ob)));
    }

    function test_P1r_ah_otherChainOrExchange_refused() public {
        (uint256 mk, address mown, address mm) = _safe("ahc-maker");
        _register(mm, mown, mown);
        X.Order memory mo = _order(mm, m, 0, false, 40, 10 * SHARE);
        assertTrue(_check(mo, _sign(mk, mo)));
        // another chain id: signed under it, presented here
        uint256 here_ = vm.getChainId();
        vm.chainId(here_ == 10143 ? 31337 : 10143);
        bytes memory forOtherChain = _sign(mk, mo);
        vm.chainId(here_);
        assertFalse(_check(mo, forOtherChain), "signed for the other chain id");
        // another exchange address: the same owner is registered there too, and the order is signed for it
        X ex2 = new X(address(usd), treasury);
        assertTrue(address(ex2) != address(ex));
        _safeExec(mm, mown, address(ex2), abi.encodeCall(X.setOrderSigner, (mown)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(mk, _hashFor(address(ex2), mo));
        bytes memory forEx2 = abi.encodePacked(r, s, v);
        assertTrue(ex2.isValidOrderSignature(mo, forEx2));
        assertFalse(_check(mo, forEx2), "signed for another exchange");
    }

    // ------------------------------------------------------------------------------------------------ (ai)
    function _stubMaker(uint256 mode, address key) internal returns (address stub) {
        stub = address(new OwnerStub(mode));
        OwnerStub(stub).register(ex, key);
    }

    function test_P1r_ai_isOwnerBurnsAllGas_badSignature_withinSigGas() public {
        uint256 honest = _honestSafeGas();
        (address key, uint256 k) = makeAddrAndKey("ai-burn");
        address stub = _stubMaker(0, key);
        X.Order memory o = _order(stub, m, 0, false, 40, 10 * SHARE);
        vm.expectCall(stub, abi.encodeWithSelector(IS_VALID_SIG), 0);
        (bool ok, uint256 used) = _checkGas(o, _sign(k, o));
        assertFalse(ok);
        assertGt(used, ex.SIG_GAS() - 1_000, "it did burn the cap");
        _assertPartyBound(used, honest, "at most 60,000 gas over an honest Safe (plan 4.2, 4.5)");
    }

    function test_P1r_ai_isOwnerReturns6MB_badSignature_noMemoryGrowth() public {
        uint256 honest = _honestSafeGas();
        (address key, uint256 k) = makeAddrAndKey("ai-6mb");
        address stub = _stubMaker(1, key);
        X.Order memory o = _order(stub, m, 0, false, 40, 10 * SHARE);
        vm.expectCall(stub, abi.encodeWithSelector(IS_VALID_SIG), 0);
        (bool ok, uint256 used) = _checkGas(o, _sign(k, o));
        assertFalse(ok);
        _assertPartyBound(used, honest, "no copy of the return data: within 60,000 gas over an honest Safe");
    }

    function test_P1r_ai_isOwnerReturns6MB_wordOne_acceptedAtBoundedCost() public {
        uint256 honest = _honestSafeGas();
        (address key, uint256 k) = makeAddrAndKey("ai-6mb-one");
        address stub = _stubMaker(7, key);
        X.Order memory o = _order(stub, m, 0, false, 40, 10 * SHARE);
        (bool ok, uint256 used) = _checkGas(o, _sign(k, o));
        // 6,000,000 bytes returned from a callee that has SIG_GAS: only Monad's linear memory price lets the callee finish
        // (plan 4.5, P1r (ai)); under Ethereum's quadratic price the callee runs out of gas and the answer is no. Either
        // way no return data is copied and the cost is bounded.
        assertEq(
            ok, vm.envOr("EXPECT_MONAD_GAS", false), "first word 1 accepted exactly where the callee can return it"
        );
        _assertPartyBound(used, honest, "bounded cost");
    }

    function test_P1r_ai_tooLittleGas_insufficientGas() public {
        (uint256 mk, address mown, address mm) = _safe("ai-gas");
        _register(mm, mown, mown);
        X.Order memory mo = _order(mm, m, 0, false, 40, 10 * SHARE);
        bytes memory data = abi.encodeCall(X.isValidOrderSignature, (mo, _sign(mk, mo)));
        (bool ok, bytes memory ret) = address(ex).staticcall{gas: 80_000}(data);
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(X.InsufficientGas.selector));
        (ok, ret) = address(ex).staticcall{gas: 500_000}(data);
        assertTrue(ok);
        assertEq(abi.decode(ret, (bool)), true);
    }

    // ------------------------------------------------------------------------------------------------ (aj)
    function test_P1r_aj_isOwnerBurnsOnlyWhenSent_settlesAtPrice0_outOfGasAtSettlerLimit_noIsValidSignature() public {
        (address key, uint256 k) = makeAddrAndKey("aj-key");
        GasPriceOwner gm = new GasPriceOwner();
        gm.register(ex, key);
        (uint256 tk, address t) = _party("aj-taker", m, 1_000 * SHARE, 0);
        _fundAddr(address(gm), 0, 100 * SHARE);
        X.Order memory to = _order(t, m, 0, true, 50, 10 * SHARE);
        X.Order memory mo = _order(address(gm), m, 0, false, 40, 10 * SHARE);
        bytes memory data = _call(to, _sign(tk, to), _one(mo), _oneSig(_sign(k, mo)), _oneFill(10 * SHARE), 10 * SHARE);
        // the maker is only ever reached through isOwner: once at gas price 0, once when sent
        vm.expectCall(address(gm), abi.encodeWithSelector(IS_VALID_SIG), 0);
        vm.expectCall(address(gm), abi.encodeWithSelector(IS_OWNER, key), 2);
        uint256 snap = vm.snapshotState();
        vm.txGasPrice(0);
        vm.prank(operator);
        uint256 g0 = gasleft();
        (bool ok0,) = address(ex).call(data);
        uint256 est = g0 - gasleft();
        assertTrue(ok0, "at gas price 0 the order is accepted and matchOrders settles");
        vm.revertToState(snap);
        uint256 limit = ((est * 11 + 9) / 10 + 999) / 1000 * 1000; // the settler limit of that estimate
        vm.txGasPrice(102 gwei);
        vm.prank(operator);
        (bool ok, bytes memory ret) = address(ex).call{gas: limit}(data);
        assertFalse(ok, "sent at the settler limit, it runs out of gas");
        assertEq(ret.length, 0, "out of gas: no revert data");
    }

    // ------------------------------------------------------------------------------------------------ the answer of isOwner, word by word
    function _stubResult(uint256 mode) internal returns (bool) {
        (address key, uint256 k) = makeAddrAndKey(string.concat("stub", vm.toString(mode)));
        address stub = _stubMaker(mode, key);
        X.Order memory o = _order(stub, m, 0, false, 40, 10 * SHARE);
        vm.expectCall(stub, abi.encodeWithSelector(IS_VALID_SIG), 0);
        return _check(o, _sign(k, o));
    }

    function test_isOwnerAnswer_onlyTheWordOne_succeeds() public {
        assertTrue(_stubResult(5), "word 1, 32 bytes");
        assertFalse(_stubResult(2), "word 2");
        assertFalse(_stubResult(3), "31 bytes");
        assertFalse(_stubResult(4), "reverts");
    }

    function test_failedOwnerCheck_neverFallsThroughTo1271() public {
        // isOwner says no and isValidSignature says yes: only a fall-through would accept
        (address key, uint256 k) = makeAddrAndKey("ft");
        address stub = _stubMaker(6, key);
        X.Order memory o = _order(stub, m, 0, false, 40, 10 * SHARE);
        // the same stub accepts the order through step 2 when the signature does not recover the registered key
        assertTrue(_check(o, new bytes(65)), "the stub's EIP-1271 does accept (control)");
        vm.expectCall(stub, abi.encodeWithSelector(IS_VALID_SIG), 0);
        assertFalse(_check(o, _sign(k, o)));
    }

    function test_registeredKeyThatIsNotAnOwner_refused() public {
        (, address own, address mm) = _safe("nonowner");
        (address stray, uint256 sk) = makeAddrAndKey("nonowner-key");
        _register(mm, own, stray); // the Safe registers a key it does not own
        X.Order memory o = _order(mm, m, 0, false, 40, 10 * SHARE);
        vm.expectCall(mm, abi.encodeWithSelector(IS_VALID_SIG), 0);
        assertFalse(_check(o, _sign(sk, o)));
    }

    // ------------------------------------------------------------------------------------------------ the other branches of step 1b
    function test_otherSignerForRegisteredMaker_refused() public {
        // a registered maker, a signature recovering a third address: step 1b is skipped, step 2 refuses
        (, address own, address mm) = _safe("third");
        _register(mm, own, own);
        (, uint256 sk) = makeAddrAndKey("third-signer");
        X.Order memory o = _order(mm, m, 0, false, 40, 10 * SHARE);
        assertFalse(_check(o, _sign(sk, o)));
    }

    function test_unregisteredSafe_plainOwnerSignature_refused() public {
        (uint256 k,, address mm) = _safe("unreg");
        X.Order memory o = _order(mm, m, 0, false, 40, 10 * SHARE);
        vm.expectCall(mm, abi.encodeWithSelector(IS_OWNER), 0);
        assertFalse(_check(o, _sign(k, o)));
    }

    function test_eoaRegistration_neverValidatesAnything() public {
        (address e, uint256 ek) = makeAddrAndKey("eoa");
        (address key, uint256 kk) = makeAddrAndKey("eoa-key");
        vm.prank(e);
        ex.setOrderSigner(key);
        X.Order memory o = _order(e, m, 0, false, 40, 10 * SHARE);
        assertFalse(_check(o, _sign(kk, o)), "the registered key has no code to check an owner on");
        assertTrue(_check(o, _sign(ek, o)), "its own key still signs for it (step 1)");
    }
}
