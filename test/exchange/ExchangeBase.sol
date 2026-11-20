// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {MakoOutcomeExchangeV1 as X} from "../../src/MakoOutcomeExchangeV1.sol";
import {MockUSDC} from "../mocks/TokenMocks.sol";

/// @notice Shared fixture for the MakoOutcomeExchangeV1 suites: one exchange, one operator, markets, EOA parties with
/// fresh keys, and order signing. The EIP-712 digest is computed HERE from the plan's text (section 4.1), never read
/// back from the contract, so a wrong domain or type string in the contract fails the suite instead of agreeing
/// with itself.
abstract contract ExchangeBase is Test {
    uint256 internal constant SHARE = 1_000_000;
    uint256 internal constant LOT = 10_000;
    uint16 internal constant FEE = 700;
    uint128 internal constant CAP = 1_000_000 * 1_000_000;

    bytes32 internal constant DOMAIN_TYPEHASH = 0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f;
    bytes32 internal constant ORDER_TYPEHASH = 0x31b03c5451c8432797ca6ddcfd89cc41597b3a6d62728cd13f8bea1090e223cc;

    MockUSDC internal usd;
    X internal ex;
    address internal treasury = makeAddr("treasury");
    address internal operator = makeAddr("operator");
    /// @dev Key of every party made by `_party`, so a test can change an order and sign it again.
    mapping(address => uint256) internal keyOf;

    /// @dev A whole `matchOrders` argument list.
    struct Call {
        X.Order t;
        bytes ts;
        X.Order[] ms;
        bytes[] mss;
        uint128[] fs;
        uint128 tf;
    }

    function setUp() public virtual {
        usd = new MockUSDC();
        ex = new X(address(usd), treasury);
        ex.setOperator(operator, true);
    }

    // ------------------------------------------------------------------------------------------------ markets
    function _market(uint8 nOpt) internal returns (uint256) {
        return _marketCap(nOpt, FEE, CAP);
    }

    function _marketCap(uint8 nOpt, uint16 fee, uint128 cap) internal returns (uint256) {
        return ex.createMarket(
            nOpt, fee, uint64(block.timestamp + 30 days), uint64(block.timestamp + 31 days), cap, bytes32(0)
        );
    }

    // ------------------------------------------------------------------------------------------------ parties
    function _deposit(address a, uint256 amt) internal {
        usd.mint(a, amt);
        vm.startPrank(a);
        usd.approve(address(ex), amt);
        ex.deposit(amt);
        vm.stopPrank();
    }

    /// @dev `sets` complete sets minted by `a` itself (its net becomes `sets`, its cash is spent).
    function _mint(address a, uint256 m, uint256 sets) internal {
        _deposit(a, sets);
        vm.prank(a);
        ex.mintSets(m, sets);
    }

    /// @dev A fresh EOA: `cashAmt` of free cash, and `sets` complete sets minted by itself.
    function _party(string memory name, uint256 m, uint256 cashAmt, uint256 sets)
        internal
        returns (uint256 pk, address a)
    {
        (a, pk) = makeAddrAndKey(name);
        keyOf[a] = pk;
        if (cashAmt != 0) _deposit(a, cashAmt);
        if (sets != 0) _mint(a, m, sets);
    }

    // ------------------------------------------------------------------------------------------------ orders
    function _order(address maker, uint256 m, uint8 option, bool isBuy, uint8 price, uint256 size)
        internal
        view
        returns (X.Order memory o)
    {
        o = X.Order({
            salt: uint256(keccak256(abi.encode(maker, m, option, isBuy, price, size))),
            maker: maker,
            marketId: m,
            option: option,
            isBuy: isBuy,
            price: price,
            size: uint128(size),
            expiration: uint64(block.timestamp + 1 days),
            nonce: uint64(ex.nonces(maker))
        });
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("Mako Market Exchange"), keccak256("1"), block.chainid, address(ex))
        );
    }

    function _hashFor(address verifying, X.Order memory o) internal view returns (bytes32) {
        bytes32 sep = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("Mako Market Exchange"), keccak256("1"), block.chainid, verifying)
        );
        bytes32 structHash = keccak256(
            abi.encode(
                ORDER_TYPEHASH, o.salt, o.maker, o.marketId, o.option, o.isBuy, o.price, o.size, o.expiration, o.nonce
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", sep, structHash));
    }

    function _hash(X.Order memory o) internal view returns (bytes32) {
        return _hashFor(address(ex), o);
    }

    function _sign(uint256 pk, X.Order memory o) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _hash(o));
        return abi.encodePacked(r, s, v);
    }

    function _one(X.Order memory o) internal pure returns (X.Order[] memory a) {
        a = new X.Order[](1);
        a[0] = o;
    }

    function _two(X.Order memory o, X.Order memory p) internal pure returns (X.Order[] memory a) {
        a = new X.Order[](2);
        a[0] = o;
        a[1] = p;
    }

    function _oneSig(bytes memory s) internal pure returns (bytes[] memory a) {
        a = new bytes[](1);
        a[0] = s;
    }

    function _twoSig(bytes memory s, bytes memory t) internal pure returns (bytes[] memory a) {
        a = new bytes[](2);
        a[0] = s;
        a[1] = t;
    }

    function _oneFill(uint256 f) internal pure returns (uint128[] memory a) {
        a = new uint128[](1);
        a[0] = uint128(f);
    }

    function _twoFill(uint256 f, uint256 g) internal pure returns (uint128[] memory a) {
        a = new uint128[](2);
        a[0] = uint128(f);
        a[1] = uint128(g);
    }

    function _settle(
        X.Order memory t,
        bytes memory ts,
        X.Order[] memory ms,
        bytes[] memory mss,
        uint128[] memory fs,
        uint256 tf
    ) internal {
        vm.prank(operator);
        ex.matchOrders(t, ts, ms, mss, fs, uint128(tf));
    }

    /// @dev One taker against one maker, both signed by their keys, at `fill`.
    function _settle1(uint256 tk, X.Order memory t, uint256 mk, X.Order memory mo, uint256 fill) internal {
        _settle(t, _sign(tk, t), _one(mo), _oneSig(_sign(mk, mo)), _oneFill(fill), fill);
    }

    function _call(
        X.Order memory t,
        bytes memory ts,
        X.Order[] memory ms,
        bytes[] memory mss,
        uint128[] memory fs,
        uint256 tf
    ) internal pure returns (bytes memory) {
        return abi.encodeCall(X.matchOrders, (t, ts, ms, mss, fs, uint128(tf)));
    }

    function _data(Call memory c) internal pure returns (bytes memory) {
        return abi.encodeCall(X.matchOrders, (c.t, c.ts, c.ms, c.mss, c.fs, c.tf));
    }

    /// @dev Signs the taker and every maker order again with the keys `_party` recorded (after a test changed them).
    function _resign(Call memory c) internal view {
        c.ts = _sign(keyOf[c.t.maker], c.t);
        for (uint256 i; i < c.ms.length; ++i) {
            c.mss[i] = _sign(keyOf[c.ms[i].maker], c.ms[i]);
        }
    }

    function _send(Call memory c) internal {
        vm.prank(operator);
        ex.matchOrders(c.t, c.ts, c.ms, c.mss, c.fs, c.tf);
    }

    /// @dev Runs the call as the operator, expecting exactly `err`, and asserts the exchange recorded no storage write
    /// (plan section 4.4: steps 1 to 5 finish before the first write).
    function _expectNoWrite(bytes memory err, bytes memory data) internal {
        vm.startStateDiffRecording();
        vm.prank(operator);
        (bool ok, bytes memory ret) = address(ex).call(data);
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        assertFalse(ok, "call should revert");
        assertEq(ret, err, "revert reason");
        for (uint256 i; i < acc.length; ++i) {
            for (uint256 j; j < acc[i].storageAccesses.length; ++j) {
                Vm.StorageAccess memory sa = acc[i].storageAccesses[j];
                if (sa.account == address(ex)) assertFalse(sa.isWrite, "exchange wrote storage");
            }
        }
    }

    /// @dev Reverts exactly `err` as the operator (state is unchanged by the revert itself).
    function _expectErr(bytes memory err, bytes memory data) internal {
        vm.prank(operator);
        (bool ok, bytes memory ret) = address(ex).call(data);
        assertFalse(ok, "call should revert");
        assertEq(ret, err, "revert reason");
    }

    // ------------------------------------------------------------------------------------------------ expected money
    function _v(uint256 fill, uint256 price) internal pure returns (uint256) {
        return fill * price / 100;
    }

    /// @dev The plan's fee formula, written out again here: ceil(rate x size x t x (100 - t) / 1e8).
    function _fee(uint256 fill, uint256 t) internal pure returns (uint256) {
        uint256 num = uint256(FEE) * fill * t * (100 - t);
        return (num + 99_999_999) / 100_000_000;
    }

    function _net(uint256 m, address w) internal view returns (uint256 n) {
        (n,) = ex.recOf(m, w);
    }

    function _held(uint256 m, address w) internal view returns (uint256 h) {
        (, h) = ex.recOf(m, w);
    }
}
