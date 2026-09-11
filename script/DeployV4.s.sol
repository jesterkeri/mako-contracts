// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {MakoMarketsV4} from "../src/MakoMarketsV4.sol";

/// @title  DeployV4 — broadcast MakoMarketsV4 and (optionally) rotate auth to the admin Safe.
///
/// @notice TWO MODES.
///
///         ROTATION MODE (default, mainnet policy):
///         Single broadcast covers the deploy AND the post-deploy auth
///         rotation (owner + resolver → admin Safe). Codex r5/r6 made the
///         rotation mandatory and ordered because:
///
///         - `setResolver(...)` is `onlyOwner`. If we rotate ownership FIRST,
///           the deployer loses authority to set the resolver, leaving the
///           contract permanently half-rotated. Order is therefore:
///             1. setResolver(adminSafe)
///             2. transferOwnership(adminSafe)
///
///         - The script is state-aware + idempotent so partial-failure
///           recovery works without manual intervention (unless the
///           contract is genuinely stuck — see "stuck half-rotation" below).
///           Pass EXISTING_MAKO_ADDRESS to skip the `new` step and only
///           run the rotation phase against an already-deployed contract.
///
///         SKIP-ROTATION MODE (`SKIP_ADMIN_ROTATION=true`, testnet policy):
///         Deploy MakoMarketsV4 and leave `owner == resolver == deployer`.
///         No `setResolver`/`transferOwnership` calls. Used to match the
///         existing testnet operating model where every prior v4 deploy
///         (3 to date as of 2026-05-18) kept the deployer EOA in both
///         roles; see project memory `project_mako_admin_rotation_deferred`.
///
///         The skip mode is strictly opt-in via env var AND chain-guarded:
///         it reverts unless `block.chainid == 10143` (Monad testnet). Any
///         other chain — mainnet, a future testnet, a forked local node —
///         falls outside skip mode. To deploy without rotation on a
///         different chain, the operator must edit this script (and
///         re-review). Mainnet deploys MUST also leave `SKIP_ADMIN_ROTATION`
///         unset/false so the script falls into rotation mode and the loud
///         `MAKO_ADMIN_SAFE_ADDRESS` guards apply.
///
///         Skip mode additionally rejects `EXISTING_MAKO_ADDRESS != 0`:
///         attaching to an already-deployed contract in skip mode could
///         silently make a "redeploy" reuse the old bytecode (codex r1
///         MAJOR). Recovery against a pristine contract via skip mode is
///         not a supported flow; use rotation mode with the state-aware
///         dispatch instead.
///
/// @dev    Env vars:
///           PRIVATE_KEY              — deployer EOA private key (BW-injected)
///           TREASURY                 — protocol-fee recipient address
///           USDC_ADDRESS             — canonical 6-decimal USDC on target chain:
///                                        Monad testnet  0x534b2f3A21130d7a60830c2Df862319e593943A3
///                                        Monad mainnet  0x754704Bc059F8C67012fEd69BC8A327a5aafb603
///           SKIP_ADMIN_ROTATION      — optional, defaults false. When `true`
///                                      the script deploys without rotating
///                                      auth; testnet-only and chain-gated
///                                      to chainid 10143 (Monad testnet).
///                                      Foundry's bool envOr accepts only
///                                      `true`/`false` (case-insensitive),
///                                      NOT `1`/`0`. Mainnet leaves this
///                                      unset.
///           MAKO_ADMIN_SAFE_ADDRESS  — destination owner + resolver after
///                                      rotation. Required when
///                                      `SKIP_ADMIN_ROTATION` is false.
///                                      Ignored when skip is true (not read).
///           EXISTING_MAKO_ADDRESS    — optional; if set, attach to existing
///                                      contract and only run rotation phase.
///                                      Used to recover from partial-failure
///                                      previous runs. REJECTED in skip mode
///                                      (hard revert before broadcast) — see
///                                      "Skip mode additionally rejects..."
///                                      note below.
///
/// @dev    Stuck half-rotation (rotation mode only): if a prior run somehow
///         left the contract with `owner == adminSafe` and `resolver != adminSafe`,
///         this script CANNOT recover — the deployer EOA no longer has owner
///         authority and `setResolver` is `onlyOwner`. The script aborts loudly
///         with instructions for the admin Safe operator to call `setResolver`
///         directly from the Safe (e.g. via Magic admin, Safe UI, or a
///         direct Safe transaction execution tool). Skip mode never hits this
///         branch because it doesn't run the dispatch table.
contract DeployV4 is Script {
    /// Monad testnet chain id. Skip-rotation mode is gated to this chain
    /// only; any other chain falls into mandatory rotation mode.
    uint256 internal constant MONAD_TESTNET_CHAIN_ID = 10143;

    function run() external returns (MakoMarketsV4 mako) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address treasury = vm.envAddress("TREASURY");
        address usdc = vm.envAddress("USDC_ADDRESS");
        address deployer = vm.addr(pk);

        // Mode selection. Default false → rotation mode (mainnet policy).
        // Foundry bool envOr accepts only `true`/`false` (case-insensitive),
        // NOT `1`/`0`. Unset defaults to false; invalid bool values (e.g.
        // `1`, `yes`) fail loudly at parse time, not silently as false.
        bool skipRotation = vm.envOr("SKIP_ADMIN_ROTATION", false);

        // Skip mode is chain-gated to Monad testnet (10143). Any other chain
        // (mainnet, forked local, future testnet) must fall into rotation mode.
        // Codex r1 MINOR-1: prevents an inherited SKIP_ADMIN_ROTATION env from
        // a prior shell session from accidentally skipping rotation on mainnet.
        if (skipRotation) {
            require(
                block.chainid == MONAD_TESTNET_CHAIN_ID,
                "SKIP_ADMIN_ROTATION is testnet-only; chainid must be 10143 (Monad testnet)"
            );
        }

        // adminSafe only read + validated in rotation mode. In skip mode
        // we leave it as the zero address and never touch it; loud banner
        // below makes the mode unmistakable in logs.
        address adminSafe = address(0);
        if (!skipRotation) {
            adminSafe = vm.envAddress("MAKO_ADMIN_SAFE_ADDRESS");
            require(adminSafe != address(0), "MAKO_ADMIN_SAFE_ADDRESS is zero");
            require(
                adminSafe != deployer,
                "MAKO_ADMIN_SAFE_ADDRESS equals deployer; rotation would be a no-op and admin/deployer must be distinct keys"
            );
        }

        // Optional recovery mode: attach to an existing contract instead of
        // deploying a fresh one. Used to complete rotations interrupted by
        // previous runs. Codex r1 MAJOR-1: forbidden in skip mode — a stale
        // EXISTING_MAKO_ADDRESS pointing at an unrotated prior deploy would
        // silently turn the redeploy into a no-op attach, with logs still
        // ending in "deploy complete." Recovery flows must use rotation mode.
        address existing = vm.envOr("EXISTING_MAKO_ADDRESS", address(0));
        if (skipRotation && existing != address(0)) {
            revert("EXISTING_MAKO_ADDRESS is not supported in skip-rotation mode; unset it or use rotation mode");
        }

        if (skipRotation) {
            console.log("=================================================");
            console.log("MODE: SKIP_ADMIN_ROTATION=true");
            console.log("  Testnet-only: deploys without rotating auth.");
            console.log("  Post-state: owner == resolver == deployer.");
            console.log("  Mainnet MUST leave SKIP_ADMIN_ROTATION unset.");
            console.log("=================================================");
        } else {
            console.log("MODE: rotation enabled. adminSafe target = ", adminSafe);
        }

        vm.startBroadcast(pk);

        if (existing == address(0)) {
            mako = new MakoMarketsV4(treasury, usdc);
            console.log("Fresh deploy.");
        } else {
            mako = MakoMarketsV4(existing);
            console.log("Recovery mode: attached to existing contract.");
        }

        address curOwner = mako.owner();
        address curResolver = mako.resolver();

        console.log("---");
        console.log("Pre-dispatch state:");
        console.log("  address:         ", address(mako));
        console.log("  owner:           ", curOwner);
        console.log("  resolver:        ", curResolver);
        console.log("  deployer:        ", deployer);
        if (!skipRotation) {
            console.log("  adminSafe target:", adminSafe);
        }
        console.log("---");

        if (skipRotation) {
            // Skip mode: no rotation. Post-asserts enforce that the contract
            // is in pristine deployer/deployer state. If someone attached to
            // a previously-rotated contract via EXISTING_MAKO_ADDRESS while
            // skip is on, the post-asserts below will catch it.
            console.log("State: skip-rotation mode. No setResolver / no transferOwnership.");
        } else {
            // 7-row state-dispatch table. See header comment for the full
            // matrix; this is the executable form.
            if (curOwner == deployer && curResolver == deployer) {
                // PRISTINE: rotate both, setResolver first (onlyOwner gate).
                console.log("State: pristine. Running setResolver then transferOwnership.");
                mako.setResolver(adminSafe);
                mako.transferOwnership(adminSafe);
            } else if (curOwner == deployer && curResolver == adminSafe) {
                // Resolver already rotated (probably from a partial prior run).
                // Deployer still owns — finish with transferOwnership.
                console.log("State: resolver already rotated. Running transferOwnership.");
                mako.transferOwnership(adminSafe);
            } else if (curOwner == deployer) {
                // resolver is "other" (some unexpected address). Deployer still
                // has owner authority so rotation is fully recoverable. Log a
                // warning and fix.
                console.log("WARN: resolver is unexpected address. Resetting and rotating.");
                mako.setResolver(adminSafe);
                mako.transferOwnership(adminSafe);
            } else if (curOwner == adminSafe && curResolver == adminSafe) {
                // Fully rotated already. No-op, just assert.
                console.log("State: already fully rotated. No action.");
            } else if (curOwner == adminSafe) {
                // STUCK HALF-ROTATION: owner is admin Safe but resolver is
                // something else (deployer or "other"). The deployer EOA no
                // longer has owner authority and cannot call setResolver.
                // Abort with operator instructions.
                console.log("=================================================");
                console.log("ERROR: STUCK HALF-ROTATION DETECTED");
                console.log("  owner:    ", curOwner, "(admin Safe)");
                console.log("  resolver: ", curResolver, "(NOT admin Safe)");
                console.log("");
                console.log("The deployer EOA has lost owner authority. setResolver");
                console.log("is onlyOwner; only the admin Safe can fix this.");
                console.log("");
                console.log("RECOVERY: from the admin Safe, call:");
                console.log("  mako.setResolver(", adminSafe, ")");
                console.log("via Magic admin, Safe UI, or a direct Safe execution");
                console.log("tool. This deploy script cannot recover this state.");
                console.log("=================================================");
                revert("STUCK_HALF_ROTATION: see console log for operator instructions");
            } else {
                // BIZARRE STATE: owner is neither deployer nor adminSafe. This
                // means someone called transferOwnership outside this script's
                // sequence. Operator needs to investigate manually.
                console.log("=================================================");
                console.log("ERROR: BIZARRE STATE - owner is neither deployer nor adminSafe");
                console.log("  owner:    ", curOwner);
                console.log("  resolver: ", curResolver);
                console.log("  deployer: ", deployer);
                console.log("  adminSafe:", adminSafe);
                console.log("");
                console.log("Investigate how ownership ended up at this address");
                console.log("before running the script again.");
                console.log("=================================================");
                revert("BIZARRE_STATE: owner is unexpected address");
            }
        }

        vm.stopBroadcast();

        // Post-dispatch invariant asserts. Branch on mode so the failure
        // messages tell an operator exactly which invariant was violated.
        // Skip mode: pristine deployer/deployer. Rotation mode: adminSafe/adminSafe.
        if (skipRotation) {
            require(mako.owner() == deployer, "POST-ASSERT (skip): owner != deployer");
            require(mako.resolver() == deployer, "POST-ASSERT (skip): resolver != deployer");
        } else {
            require(mako.owner() == adminSafe, "POST-ASSERT: owner != adminSafe");
            require(mako.resolver() == adminSafe, "POST-ASSERT: resolver != adminSafe");
        }

        console.log("=================================");
        if (skipRotation) {
            console.log("MakoMarketsV4 deploy complete (rotation SKIPPED)");
        } else {
            console.log("MakoMarketsV4 deploy + rotation complete");
        }
        console.log("  address:         ", address(mako));
        console.log("  owner:           ", mako.owner());
        console.log("  resolver:        ", mako.resolver());
        console.log("  treasury:        ", mako.treasury());
        console.log("  usdc:            ", address(mako.usdc()));
        console.log("  nextMarketId:    ", mako.nextMarketId());
        console.log("  protocolFeeBps:  ", mako.protocolFeeBps());
        console.log("  creatorFeeBps:   ", mako.creatorFeeBps());
        console.log("  minLiquidityBps: ", mako.minLiquidityRatioBps());
        console.log("  MIN_BET (USDC):  ", mako.MIN_BET());
        console.log("  MIN_CREATOR_SEED:", mako.MIN_CREATOR_SEED());
        console.log("=================================");
        console.log("Next steps:");
        console.log("  1. Set NEXT_PUBLIC_MAKO_ADDRESS in mako-markets/.env.local");
        console.log("  2. Sync v4 ABI to scripts/mako-abi.json + cf-worker/src/mako-abi.json");
        console.log("  3. Record deploy block for NEXT_PUBLIC_MAKO_DEPLOY_BLOCK");
        if (skipRotation) {
            console.log("  4. Leave NEXT_PUBLIC_MAKO_ADMIN_SAFE_ADDRESS unset/zero;");
            console.log("     MAKO admin-create stays fail-closed in aa-call-allowlist.");
        } else {
            console.log("  4. Verify MAKO_ADMIN_SAFE_ADDRESS env is mirrored in mako-markets aa-constants.ts");
        }
    }
}
