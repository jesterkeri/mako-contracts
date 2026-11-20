// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

/// @notice EIP-1271 wallets that misbehave in every way the exchange's bounded check (plan section 4.2) must survive.
/// @dev `isValidSignature` is `view`, as in the standard, so the modes cannot write; they read gas and return data.
contract Wallet1271 {
    enum Mode {
        HONEST, // magic only for the exact (hash, signature bytes) the owner approved
        REVERT,
        WRONG_MAGIC,
        SHORT_RETURN, // 4 bytes returned
        BURN, // infinite loop: consumes all the gas it is given
        BOMB, // returns the magic word in front of ~190 KB, within the 100,000 gas
        NEEDS_MORE_GAS, // approves only with more than SIG_GAS: never, under the bound
        NEEDS_95K, // approves with more than 95,000 gas left: yes, under the bound
        DIRTY_TAIL, // magic in the first 4 bytes, garbage after: not the exact word
        ALWAYS_OK, // magic for anything: a lying wallet, safe only because the maker signed
        TWO_WORDS // magic word then a second word: accepted, only 32 bytes are read
    }

    Mode public mode;
    mapping(bytes32 => bytes32) public approved;

    function setMode(Mode m) external {
        mode = m;
    }

    function approve(bytes32 orderHash, bytes calldata sig) external {
        approved[orderHash] = keccak256(sig);
    }

    function isValidSignature(bytes32 hash, bytes calldata sig) external view returns (bytes4) {
        Mode m = mode;
        if (m == Mode.HONEST) {
            return approved[hash] == keccak256(sig) && approved[hash] != 0 ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
        }
        if (m == Mode.REVERT) revert("no");
        if (m == Mode.WRONG_MAGIC) return 0x1626ba7f;
        if (m == Mode.SHORT_RETURN) {
            assembly {
                mstore(0, shl(224, 0x1626ba7e))
                return(0, 4)
            }
        }
        if (m == Mode.BURN) {
            while (true) {}
        }
        if (m == Mode.BOMB) {
            assembly {
                mstore(0, shl(224, 0x1626ba7e))
                return(0, 190000)
            }
        }
        if (m == Mode.NEEDS_MORE_GAS) return gasleft() > 100_000 ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
        if (m == Mode.NEEDS_95K) return gasleft() > 95_000 ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
        if (m == Mode.DIRTY_TAIL) {
            assembly {
                mstore(0, or(shl(224, 0x1626ba7e), 1))
                return(0, 32)
            }
        }
        if (m == Mode.TWO_WORDS) {
            assembly {
                mstore(0, shl(224, 0x1626ba7e))
                mstore(32, 7)
                return(0, 64)
            }
        }
        return 0x1626ba7e; // ALWAYS_OK
    }
}
