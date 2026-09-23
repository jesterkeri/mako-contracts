// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

/// @notice Minimal hand-written interface to Chainlink's Data Streams `VerifierProxy`.
///
/// @dev Four members, not two. `typeAndVersion` and `s_accessController` are here because the fork
/// test's identity assertion needs them, and an earlier draft advertised them without declaring
/// them. The repository has no Chainlink contracts package as a dependency and `MakoMarketsV4` already inlines
/// its own minimal `IERC20`, so this matches that convention rather than adding one.
///
/// Verified against the deployed contract on Monad testnet at block 62922075 on 2026-09-23:
/// `typeAndVersion` is "VerifierProxy 2.0.0", the runtime code is 7,009 bytes with keccak256
/// `0x4bd86e898b2952f6f0d20fee037accf52490dbdd9279345cd4b0a7161b5c022b`, and both `s_feeManager` and
/// `s_accessController` return the zero address.
interface IVerifierProxy {
    /// @notice Verifies a Data Streams report and returns the verified payload.
    ///
    /// @dev `payable` because that is what the real proxy declares. This is precisely why
    /// `RoundSettlement.check` cannot be `view`: solc rejects a `view` function making this call
    /// with `Error (8961): Function cannot be declared as view because this expression
    /// (potentially) modifies the state`. Confirmed by compiling it both ways under solc 0.8.24.
    ///
    /// Mako never sends value and always passes an empty `parameterPayload`: a non-empty value
    /// engages fee handling, and `s_feeManager()` being zero is checked first regardless.
    ///
    /// @param payload the 736-byte v3 `fullReport`
    /// @param parameterPayload must be empty, per SPEC 5.2 step 2
    /// @return the verified report blob, 288 bytes for schema v3
    function verify(bytes calldata payload, bytes calldata parameterPayload) external payable returns (bytes memory);

    /// @notice The fee manager, if one is configured.
    /// @dev SPEC 5.2 step 1 requires this to be zero BEFORE `verify` is called. `KNOWN-LIMITS.md` 21
    /// records that a fee manager appearing would break settlement outright, and this is the only
    /// fee defence in the system: `nativeFee` and `linkFee` are non-zero in every real report and no
    /// check examines them.
    function s_feeManager() external view returns (address);

    /// @notice The access controller, if one is configured.
    /// @dev Storage, so it can turn non-zero without the bytecode changing, and a non-zero value can
    /// stop a permissionless caller verifying at all. Asserted by the fork test and by the retention
    /// observation, not by the settlement rule.
    function s_accessController() external view returns (address);

    /// @notice Identity string, asserted by the fork test before the verifier's answers are trusted.
    function typeAndVersion() external view returns (string memory);
}
