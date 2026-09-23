# Archive probe evidence

Three runs on 2026-09-23, kept in order because the sequence is the point.

| run | status | proofLevel | operators |
|---|---|---|---|
| `10-05-57` | VERIFIED_MATCH | one-domain | unknown + unknown |
| `15-40-59` | VERIFIED_MATCH | one-domain | unknown + Alchemy Insights, Inc. |
| `15-44-45` | **VERIFIED_MATCH** | **two-distinct-operators** | **QuickNode + Monad Foundation** |

All three returned byte-identical payloads, sha256 `be8b5132423d7e7926f2bdc50917d000…`, at
block 62922075 with hash `0x73f54743…a722d6` and timestamp 1789529160.

**Only the third is the proof.** The first two are labelled `one-domain` and, per
`PROOF_STANDARD.md` Version 3 §1b, do not satisfy that section. They are retained as
diagnostics rather than deleted, because what changed between the second and the third was
**not the chain and not the bytes**: it was `script/providers.json` recording the operators
Monad had published all along.

The first two runs record `operator: "unknown"` for `testnet-rpc.monad.xyz`. That was an
omission, not a fact about the world. Monad's own testnet documentation names QuickNode as
its provider and Monad Foundation as the provider for `rpc-testnet.monadinfra.com`:
https://docs.monad.xyz/developer-essentials/testnet (read 2026-09-23). Once recorded, an
agreement that had existed since the 10-05 run qualified as a two-operator proof.

Two things worth keeping in mind when reading these files:

- **The 15-40 run would now qualify.** QuickNode and Alchemy are distinct operators, so that
  run's `one-domain` label reflects the metadata at the time, not its actual independence.
  It is not re-run here because the 15-44 pair already proves the claim without a credential.
- **QuickNode's own service and `testnet-rpc.monad.xyz` are the same operator.** Pairing them
  would look like two providers and be one failure domain. `providers.json` says so explicitly.
