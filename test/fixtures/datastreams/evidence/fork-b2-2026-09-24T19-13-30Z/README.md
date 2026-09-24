# B2 fork evidence, 2026-09-24

PROOF_STANDARD.md Version 3 Type **B2**: `test/RoundSettlementFork.t.sol` run against the REAL
Chainlink VerifierProxy on a Monad testnet fork at block **62922075** (timestamp 1789529160, the
mandatory fixture's observation second), through two distinct operators.

| File | Provider | Operator |
|---|---|---|
| `quicknode.txt` | testnet-rpc.monad.xyz | QuickNode |
| `monad-foundation.txt` | rpc-testnet.monadinfra.com | Monad Foundation |

Operators per https://docs.monad.xyz/developer-essentials/testnet (read 2026-09-23).

Command: `MAKO_FORK_RPC=<url> forge test --network monad --match-contract RoundSettlementFork -vvv`
Commit: 505f987 plus the working-tree changes committed alongside this record.
Tools: forge Version: 1.8.1

The endpoint alias is the `MAKO_FORK_RPC` environment variable; no key is involved (both are public).
