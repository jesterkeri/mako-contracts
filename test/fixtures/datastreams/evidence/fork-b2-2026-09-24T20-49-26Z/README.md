# B2 fork evidence, 2026-09-24 (block-hash gated)

PROOF_STANDARD.md Version 3 Type **B2**: `test/RoundSettlementFork.t.sol` against the REAL Chainlink
VerifierProxy on a Monad testnet fork, through two distinct operators.

| | |
|---|---|
| Block | **62922075** |
| Block hash | **0x73f54743b7db644c8f010e74f422107337b586b59fed5a91916f98b384a722d6**, read from each provider via BLOCKHASH at block 62922076 and REQUIRED in setUp |
| Block timestamp | 1789529160, asserted |
| Chain id | 10143, asserted |

| File | Provider | Operator | Result |
|---|---|---|---|
| `quicknode.txt` | testnet-rpc.monad.xyz | QuickNode | 7 passed, served hash matches |
| `monad-foundation.txt` | rpc-testnet.monadinfra.com | Monad Foundation | 7 passed, served hash matches |

Operators per https://docs.monad.xyz/developer-essentials/testnet (read 2026-09-23).

**The hash gate is proven to fail:** with a wrong pinned hash, setUp reverts "provider served a
different block at the pinned height" and no test runs.

Command: `MAKO_FORK_RPC=<url> forge test --network monad --match-contract RoundSettlementFork -vvv`
Tools: forge Version: 1.8.1

Supersedes `fork-b2-2026-09-24T19-13-30Z`, which is kept but did not check the block hash.
