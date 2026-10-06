// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployRoundsV1} from "../script/DeployRoundsV1.s.sol";

/// @notice Adversary pass on T1.5 (3a55b20): attacks on `decodeReceipt`, the decoder of forge's `vm.rpc` encoding
/// of an `eth_getTransactionReceipt` object. Receipts are rebuilt with Solidity's own `abi.encode` of a struct that
/// mirrors forge's layout, and the rebuild is first asserted byte-equal to the captured fixture
/// (test/fixtures/receipts/monad-v4-create-receipt.hex), so every mutation starts from the real chain's bytes.
///   offline: forge test --match-contract DeployRoundsV1ReceiptDecodeAdversary -vvv
///   fork:    MAKO_FORK_RPC=https://testnet-rpc.monad.xyz/ forge test --network monad --match-contract DeployRoundsV1ReceiptDecodeAdversary -vvv
contract DeployRoundsV1ReceiptDecodeAdversary is Test {
    DeployRoundsV1 internal script;

    bytes32 internal constant V4_CREATE = 0x820d7d68d9bf1bf54aa15cd33370e8baac6bd7e57b0670509a26f137ced39740;
    address internal constant V4 = 0xbC5A58487D7949dA2B76aC84AfC032fD0aa26195;
    uint256 internal constant V4_BLOCK = 0x1f17e1e;

    /// forge's encoding of the 14-field Monad receipt: quantities as bytes, null as a zero word.
    struct R14 {
        bytes32 blockHash;
        bytes blockNumber;
        address contractAddress;
        bytes cumulativeGasUsed;
        bytes effectiveGasPrice;
        address from;
        bytes gasUsed;
        uint256[] logs;
        bytes logsBloom;
        bytes status;
        address to;
        bytes32 transactionHash;
        bytes transactionIndex;
        bytes type_;
    }

    /// A future shape: `blobGasUsed` (sorts first) added, `effectiveGasPrice` dropped. Still 14 fields, so
    /// `transactionHash` stays at index 11.
    struct R14Blob {
        bytes blobGasUsed;
        bytes32 blockHash;
        bytes blockNumber;
        address contractAddress;
        bytes cumulativeGasUsed;
        address from;
        bytes gasUsed;
        uint256[] logs;
        bytes logsBloom;
        bytes status;
        address to;
        bytes32 transactionHash;
        bytes transactionIndex;
        bytes type_;
    }

    /// A future shape: `blockTimestamp` (between blockNumber and contractAddress) added, `effectiveGasPrice` dropped.
    struct R14Ts {
        bytes32 blockHash;
        bytes blockNumber;
        bytes blockTimestamp;
        address contractAddress;
        bytes cumulativeGasUsed;
        address from;
        bytes gasUsed;
        uint256[] logs;
        bytes logsBloom;
        bytes status;
        address to;
        bytes32 transactionHash;
        bytes transactionIndex;
        bytes type_;
    }

    function setUp() public {
        script = new DeployRoundsV1();
    }

    function _fixture() internal view returns (bytes memory) {
        return vm.parseBytes(vm.trim(vm.readFile("test/fixtures/receipts/monad-v4-create-receipt.hex")));
    }

    function _v4() internal pure returns (R14 memory r) {
        r.blockHash = 0x617a09483f44636eec2ca3e089af36a18c0d05daf746fe113f7ea364b057e842;
        r.blockNumber = hex"01f17e1e";
        r.contractAddress = V4;
        r.cumulativeGasUsed = hex"748d52";
        r.effectiveGasPrice = hex"17bfac7c00";
        r.from = 0xC8BF886f73E4371CBd8160EEA7683b8Da98190F1;
        r.gasUsed = hex"348af5";
        r.logsBloom = new bytes(256);
        r.status = hex"01";
        r.to = address(0);
        r.transactionHash = V4_CREATE;
        r.transactionIndex = hex"04";
        r.type_ = hex"00";
    }

    function _accepts(bytes memory enc) internal view returns (bool ok, DeployRoundsV1.ChainReceipt memory rc) {
        try script.decodeReceipt(enc, V4_CREATE) returns (DeployRoundsV1.ChainReceipt memory got) {
            return (true, got);
        } catch {
            return (false, rc);
        }
    }

    /// The "passes checkOnChain" predicate for rounds = V4 at V4_BLOCK.
    function _wouldPass(bytes memory enc) internal view returns (bool) {
        (bool ok, DeployRoundsV1.ChainReceipt memory rc) = _accepts(enc);
        return ok && rc.found && rc.status == 1 && rc.to == address(0) && rc.contractAddress == V4
            && rc.blockNumber == V4_BLOCK;
    }

    function test_RebuildIsByteEqualToTheCapturedFixture() public view {
        assertEq(abi.encode(_v4()), _fixture());
        assertTrue(_wouldPass(_fixture()));
    }

    // ---- shape drift ----

    function test_ExtraLeadingFieldIsRefused() public view {
        bytes memory f = _fixture();
        // blobGasUsed inserted at index 0: rebuild as a 15-field tuple by hand is equivalent to shifting the head.
        R14Blob memory b;
        R14 memory v = _v4();
        b.blobGasUsed = hex"00";
        (b.blockHash, b.blockNumber, b.contractAddress, b.cumulativeGasUsed) =
        (v.blockHash, v.blockNumber, v.contractAddress, v.cumulativeGasUsed);
        (b.from, b.gasUsed, b.logsBloom, b.status, b.to, b.transactionHash, b.transactionIndex, b.type_) =
        (v.from, v.gasUsed, v.logsBloom, v.status, v.to, v.transactionHash, v.transactionIndex, v.type_);
        assertFalse(_wouldPass(abi.encode(b)), "blobGasUsed added, effectiveGasPrice dropped: misread as valid");
        assertTrue(f.length > 0);
    }

    function test_TimestampAddedAndGasPriceDroppedIsRefused() public view {
        R14Ts memory t;
        R14 memory v = _v4();
        t.blockTimestamp = hex"68e3a1b0";
        (t.blockHash, t.blockNumber, t.contractAddress, t.cumulativeGasUsed) =
        (v.blockHash, v.blockNumber, v.contractAddress, v.cumulativeGasUsed);
        (t.from, t.gasUsed, t.logsBloom, t.status, t.to, t.transactionHash, t.transactionIndex, t.type_) =
        (v.from, v.gasUsed, v.logsBloom, v.status, v.to, v.transactionHash, v.transactionIndex, v.type_);
        assertFalse(_wouldPass(abi.encode(t)), "blockTimestamp added, effectiveGasPrice dropped: misread as valid");
    }

    // ---- field encodings ----

    function test_StatusZeroIsReadAsZero() public view {
        R14 memory v = _v4();
        v.status = hex"00";
        (bool ok, DeployRoundsV1.ChainReceipt memory rc) = _accepts(abi.encode(v));
        assertTrue(ok);
        assertEq(rc.status, 0);
    }

    function test_StatusLeadingZeroBytesStillOne() public view {
        R14 memory v = _v4();
        v.status = hex"0001";
        (bool ok, DeployRoundsV1.ChainReceipt memory rc) = _accepts(abi.encode(v));
        assertTrue(ok);
        assertEq(rc.status, 1);
    }

    function test_EmptyOrOversizedQuantitiesAreRefused() public view {
        R14 memory v = _v4();
        v.status = "";
        assertFalse(_wouldPass(abi.encode(v)));
        v = _v4();
        v.blockNumber = abi.encodePacked(uint8(0), uint256(V4_BLOCK)); // 33 bytes, value V4_BLOCK
        assertFalse(_wouldPass(abi.encode(v)));
    }

    function test_StatusAsJsonNumberIsRefused() public view {
        // A JSON number becomes a static uint word in the head; it must not be read as an offset to "1".
        bytes memory f = _fixture();
        _put(f, 0x20 + 32 * 9, 1);
        assertFalse(_wouldPass(f));
    }

    function test_CallWithContractAddressAlsoSetIsNotAccepted() public view {
        R14 memory v = _v4();
        v.to = address(0x1000);
        assertFalse(_wouldPass(abi.encode(v)));
    }

    function test_WideAddressWordIsRefused() public {
        bytes memory f = _fixture();
        _put(f, 0x20 + 32 * 2, uint256(uint160(V4)) | (uint256(1) << 160));
        vm.expectRevert(abi.encodeWithSelector(DeployRoundsV1.NotOnChain.selector, "receipt layout"));
        script.decodeReceipt(f, V4_CREATE);
    }

    function test_OffsetsOutsideTheBufferAreRefused() public view {
        bytes memory f = _fixture();
        _put(f, 0x20 + 32 * 9, f.length);
        assertFalse(_wouldPass(f));
        f = _fixture();
        _put(f, 0x20 + 32 * 1, type(uint256).max - 0x10);
        assertFalse(_wouldPass(f));
        f = _fixture();
        _put(f, 0, type(uint256).max - 0x10);
        assertFalse(_wouldPass(f));
    }

    /// A tuple offset other than 0x20 and trailing data are valid ABI; the decoder must read the same values.
    function test_NonCanonicalButValidAbiReadsTheSameValues() public view {
        bytes memory f = _fixture();
        bytes memory shifted = abi.encodePacked(uint256(0x40), uint256(0xdead), _slice(f, 0x20), new bytes(64));
        (bool ok, DeployRoundsV1.ChainReceipt memory rc) = _accepts(shifted);
        assertTrue(ok);
        assertEq(rc.blockNumber, V4_BLOCK);
        assertEq(rc.contractAddress, V4);
    }

    // ---- live: other transaction types, read through the pinned endpoint ----

    /// Values from eth_getTransactionReceipt on https://testnet-rpc.monad.xyz/, read 2026-10-06 (head 68643008).
    function test_ForkDecodesType1AndType2Calls() public {
        string memory rpc = vm.envOr("MAKO_FORK_RPC", string(""));
        vm.skip(bytes(rpc).length == 0, "MAKO_FORK_RPC is not set: fork test SKIPPED, which is NOT a pass");
        bytes32 t2 = 0xd6c6f97a1dc35d56ffaf1bdac5a81c7ba2ef68e1a65038d3a7d4d255286fd06d;
        bytes32 t1 = 0xa76562101d4436fd80808febf2788fa6692af777d62d30c3da538711a43ed333;
        DeployRoundsV1.ChainReceipt memory a = script.decodeReceipt(
            vm.rpc("monad_testnet", "eth_getTransactionReceipt", string.concat('["', vm.toString(t2), '"]')), t2
        );
        assertEq(a.blockNumber, 0x41768bb);
        assertEq(a.status, 1);
        assertEq(a.to, 0x1964C32f0bE608E7D29302AFF5E61268E72080cc);
        assertEq(a.contractAddress, address(0));
        DeployRoundsV1.ChainReceipt memory b = script.decodeReceipt(
            vm.rpc("monad_testnet", "eth_getTransactionReceipt", string.concat('["', vm.toString(t1), '"]')), t1
        );
        assertEq(b.blockNumber, 0x41768a6);
        assertEq(b.to, 0x2e078739af50E5e98F164B9463B2a4a73E4d1a78);
    }

    function _put(bytes memory b, uint256 at, uint256 w) internal pure {
        assembly {
            mstore(add(add(b, 32), at), w)
        }
    }

    function _slice(bytes memory b, uint256 from) internal pure returns (bytes memory out) {
        out = new bytes(b.length - from);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = b[from + i];
        }
    }
}
