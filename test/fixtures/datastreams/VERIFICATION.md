# VERIFICATION: T0.1, the rounds settlement rule

The record `PROOF_STANDARD.md` Version 3 §13 requires. Every claim below declares its **proof type**
per §0: **A** offline, **B1** direct `eth_call`, **B2** Foundry fork, **C** transaction.

**T0.1 produces Type A and Type B claims and no Type C claim.** That is not a gap: there is no rounds
deployment to transact against, and `INVARIANTS.md:45` requires this rule test to run before the
contract exists. The narrow pre-contract exception in `TASKS.md`, set by Joshua on 2026-09-23, defers
§2's settlement-answer computation and cross-check and §6's real transaction to T1.1, and both still
block deployment.

---

## What this proves

The shipping rule library accepts and rejects exactly what `SPEC.md` §5.2 specifies, against the real
`VerifierProxy` at a finalized historical block, and against return shapes the real verifier will not
produce. **Nothing about rounds.** No outcome is derived, no price is taken as input, and no
settlement occurs.

## What this does not prove, and who owns it

| Not proven here | Owner |
|---|---|
| A settlement outcome (UP / DOWN / Tie) | T1.1 |
| `block.timestamp >= observationsTimestamp`, rejecting a future observation | T1.1 |
| An independent cross-check of a settled answer against another oracle | T1.1 |
| A real on-chain settlement transaction | T1.1, and T2.0 for the keeper path |
| Round lifecycle, fees, conservation | T1.1, T1.2 |
| Keeper liveness and censorship disclosure | T2.0 |
| Capacity at the maximum concurrent round count | T0.1c, T1.2 |

## Retained trust, which Mako does not hold

- **Chainlink controls the verifier's configuration.** It can add a fee manager, set an access
  controller, or register a further signing configuration. `KNOWN-LIMITS.md` 21 records that a fee
  manager would break settlement outright.
- **The rule cannot see which signing configuration signed a report.** The configuration digest is in
  `ctx[0]` of the submitted 736 bytes, not in the 288-byte verified return, so a report signed under a
  second configuration registered on the same proxy passes every on-chain check. Pinning the digest
  off chain **detects drift in the evidence we collect; it does not prevent the verifier accepting a
  rotated configuration**, and nothing in Mako's control can.
- **`nativeFee` and `linkFee` are non-zero in every real report and no check examines them.** The only
  fee defence is `s_feeManager()` being zero on the pinned verifier. Measured on the mandatory
  fixture: `nativeFee` 132,915,204,253,287 wei and `linkFee` 29,384,890,485,513,791.
- **`VerifierProxy.verify` does not enforce expiry.** Measured 2026-09-22: a report three days past
  `expiresAt` still returned 352 bytes at `latest`. SPEC §5.2 step 7 is the only expiry defence
  anywhere in this system, which is why its mutation rows are load-bearing rather than routine.

## Untrusted inputs

`fullReport` and the boundary `B` are attacker-chosen. The verifier's return is trusted only after the
288-byte and `0x0003` checks. **The verifier address is not an input at all**: it is a library
constant. The handoff to T1.1 is therefore not "make it immutable" but *call this fixed-address
library rather than reintroduce a verifier parameter, and separately enforce
`block.timestamp >= observationsTimestamp`*.

---

## §1 Real data, with provenance

### 1a. Report acquisition (Type A record, one source by nature)

| | |
|---|---|
| Report | BTC/USD, observed 2026-09-16 03:26:00 UTC |
| Source | `https://api.testnet-dataengine.chain.link/api/v1/reports?feedID=0x00037da0…b439&timestamp=1789529160` |
| Captured | 2026-09-23 09:23:44 UTC, by `mako-design/scripts/datastreams-retention.mjs` |
| `validFromTimestamp` | 1789529157 (03:25:57 UTC) |
| `observationsTimestamp` | 1789529160 (03:26:00 UTC) |
| Window | **exactly 3 seconds** |
| Bytes | 736 |
| sha256 | `66221f89a40380a39eed86b99ece466f796227282bdde3a7869234b3f68e1dc8` |
| `ctx[0]` | `0x00090d9e8d96765a0c49e03a6ae05c82e8f8de70cf179baa632f18313e54bd69`, equal to the pinned `CONFIG_DIGEST` |
| Vendored at | `test/fixtures/datastreams/pending/btcusd-1789529160.json` |
| Raw evidence | `mako-design/bench/datastreams-retention/2026-09-23T09-23-44-266Z/` |

**Why this specific report.** `INVARIANTS.md:12` requires it by name, because it is the only captured
report with `validFromTimestamp < observationsTimestamp`, which is the one direction §5.2 step 5
permits. Measured on 2026-09-23: **six of six** sampled historical reports have a zero-width window, so
a genuine widened window is rare and no mock can substitute for it.

**Retention.** The tested REST endpoint serves a measured **30 days**, stated in its own 400 body:
*"Timestamp out of bounds. Timestamp must be within the last 30 days."* Served at 21 days, refused at
30. That is the same window as `expiresAt`, so a report is re-fetchable for exactly as long as Mako
would accept it. **The committed bytes are the only copy after that**, which is why they are vendored
and checksummed rather than fetched on demand.

### 1b. Verification evidence (Type B1, two distinct operators)

| | |
|---|---|
| Block | **62922075**, hash `0x73f54743b7db644c8f010e74f422107337b586b59fed5a91916f98b384a722d6` |
| Block timestamp | 1789529160, **equal to the observation second exactly** |
| Provider A | `testnet-rpc.monad.xyz`, operator **QuickNode** |
| Provider B | `rpc-testnet.monadinfra.com`, operator **Monad Foundation** |
| Operator source | `https://docs.monad.xyz/developer-essentials/testnet`, read 2026-09-23 |
| `proofLevel` | **two-distinct-operators** |
| Raw return | 352 bytes: envelope offset 32, length 288, payload 288 |
| Payload sha256 | `be8b5132423d7e7926f2bdc50917d000a1b0dbde49db8d01a78be57d94b410ef`, **identical from both** |
| Verifier identity | chain id 10143, `VerifierProxy 2.0.0`, 7,009 bytes, `s_feeManager` 0, `s_accessController` 0, on both |
| Evidence | `test/fixtures/datastreams/evidence/archive-probe-2026-09-23T15-44-45-628Z/RESULT.json` |
| Command | `MAKO_RPC_A=… MAKO_RPC_B=… node script/probe-archive.mjs --as-proof` |

**The block timestamp equals `max(observationsTimestamp)` exactly**, so the plan's containment bound
`max(obs) <= blockTimestamp <= min(expiresAt)` holds at the earliest possible point and `vm.warp` has
the full 30 days to work in.

**Alchemy, recorded because it was measured.** On 2026-09-23 Alchemy served the same block
byte-identically, and the "monthly capacity exceeded" 429 that had blocked every call since
2026-09-21 has cleared. Its run, `archive-probe-2026-09-23T15-40-59-836Z`, is labelled `one-domain`
because it predates the operator correction; QuickNode and Alchemy are in fact distinct operators, so
it would qualify today. It is not re-run because the credential-free pair already proves the claim.

**A trap recorded so it is not walked into:** QuickNode's own service and `testnet-rpc.monad.xyz` are
**the same operator**. Pairing them would look like two providers and be one failure domain.

### The decoded report

| Field | Value |
|---|---|
| `feedId` | `0x00037da06d56d083fe599397a4769a042d63aa73dc4ef57709d31e9971a5b439` |
| `validFromTimestamp` | 1789529157 |
| `observationsTimestamp` | 1789529160 |
| `expiresAt` | 1792121160, **exactly 30.00 days** after observation |
| `price` | 75938791787880000000000 ($75,938.79) |
| `bid` / `ask` | 75935199000000000000000 / 75944083700820000000000 |
| Spread | **1.17 bps**, against `MAX_SPREAD_BPS` 50 |

---

## §2 Independent computation

**T0.1 claims §2's independent computation OF THE RULE, and nothing more.** The settlement-answer
computation and the oracle cross-check are T1.1's, per the `TASKS.md` exception.

Two implementations, sharing no code, both driven from `test/fixtures/rule-cases/CASES.json` as
**data**:

| | |
|---|---|
| Production | `src/RoundSettlement.sol`, asserted by `test/RoundSettlement.t.sol` |
| Reference | `script/rule-reference.mjs`, its own decoder, no import from the generator |

Each asserts its own verdict against the corpus's expected value **first**; the two agree
transitively. The failure mode that invites is both implementing the same misreading while the
hand-authored expectation shares it. Two things defend against it, and neither is the comparison:
every row names the SPEC clause it comes from in `specClauses`, and **each evaluator is mutation
tested separately with the corpus held fixed**.

**The corpus generator never computes an expected result.** Every verdict and selector is authored by
hand from §5.2; `script/build-cases.mjs` only encodes declared field values into bytes. Its encoder is
validated against the chain rather than against itself: it re-encodes the real verifier's return from
its decoded fields and asserts byte-identity with what Monad returned. It matches.

---

## §3 Spec-first tests

`test/fixtures/rule-cases/CASES.json`, **24 rows, 4 accept and 20 reject**, written before the
implementation. Each row carries an immutable id, its `specClauses`, the raw verifier behaviour, the
boundary, the warp timestamp, and the expected verdict with its exact error selector. **The mock is
driven only by the raw behaviour, never by the expected output.**

`test/RuleCorpus.t.sol` asserts coverage: every N1 named test has a row, every N11 clause has a row,
both sides of the expiry boundary are present, ids are unique, and the mandatory widened-window row is
the real report rather than a mock.

### A case that cannot be built, recorded so it is not attempted

The build plan's mutation table asked for *"a mock returning a blob with the correct `feedId` and a
wrong prefix"*, to exercise admission by the `0x0003` check. **That byte string does not exist.** The
schema prefix **is** the first two bytes of `feedId`: the verified payload's word 0 is the feed id,
and `FEED_ID` begins `0x0003`. So `feedId == FEED_ID` logically implies `prefix == 0x0003`. Verified
against the real verified payload on 2026-09-23.

Consequently **the `0x0003` check can never be proven as admission by any input**, only as ordering
and error specificity. That is exactly what the v8 and v11 rows do: with the prefix check deleted they
still reject, as `WrongFeed`, so only asserting the exact selector detects the mutation. Recorded in
`CASES.json` under `_impossibleCases`.

---

## §4 Mutation testing

Both evaluators are mutated **separately**, with the corpus unchanged. A corpus that can absorb a
mutation is not a gate.

| | Command | Result |
|---|---|---|
| JavaScript | `node script/mutate-reference.mjs` | 13 mutations, **13 killed** |
| Solidity | `node script/mutate-solidity.mjs` | see the table below |

Every mutation runs on a copy in a temp directory. `git checkout` is never used, per the standing rule
about undoing uncommitted work, and both runners assert the working-tree file is byte-identical to
where it started.

**Solidity, `src/RoundSettlement.sol`: 15 mutations, 15 killed, 0 survived.** Every one was
caught at RUNTIME by a named test, not merely by failing to compile.

| § | Mutation | Killed by |
|---|---|---|
| step 1 | delete the fee-manager gate | `test_FeeManagerCheckRunsBeforeVerify`, `test_LibraryAgreesWithTheCorpusOnEveryMockRow` |
| step 2 | pass a non-empty parameterPayload | `test_LibraryAgreesWithTheCorpusOnEveryMockRow`, `test_VerifierCalledWithEmptyParameterPayload` |
| step 3 | accept any verified length | `test_LibraryAgreesWithTheCorpusOnEveryMockRow` |
| step 3 | drop the 0x0003 prefix check | `test_LibraryAgreesWithTheCorpusOnEveryMockRow` |
| step 4 | skip the feed comparison | `test_LibraryAgreesWithTheCorpusOnEveryMockRow` |
| step 5 | allow observationsTimestamp != boundary | `test_LibraryAgreesWithTheCorpusOnEveryMockRow` |
| step 5 | allow validFrom after the observation | `test_LibraryAgreesWithTheCorpusOnEveryMockRow` |
| step 6 | accept a non-positive price | `test_LibraryAgreesWithTheCorpusOnEveryMockRow` |
| step 6 | drop bid <= price <= ask | `test_LibraryAgreesWithTheCorpusOnEveryMockRow` |
| step 6 | compare the spread with >= instead of > | `test_LibraryAgreesWithTheCorpusOnEveryMockRow` |
| step 6 | widen MAX_SPREAD_BPS to 51 | `test_LibraryAgreesWithTheCorpusOnEveryMockRow` |
| step 6 | take the spread difference in int192 | `test_LibraryAgreesWithTheCorpusOnEveryMockRow` |
| step 7 | use >= for expiry instead of > | `test_LibraryAgreesWithTheCorpusOnEveryMockRow` |
| step 7 | delete the expiry check | `test_LibraryAgreesWithTheCorpusOnEveryMockRow` |
| step 3 | decode the SUBMITTED bytes instead of the verified return | `test_LibraryAgreesWithTheCorpusOnEveryMockRow` |

Three of those kills justify rows that would otherwise look like padding:

- **`>=` instead of `>` on the spread** is caught only by `accept-spread-exactly-at-limit`.
- **`>=` instead of `>` on expiry** is caught only by `accept-at-expiry-boundary`.
- **taking the difference in int192** is caught only by `reject-spread-max-integer-must-not-panic`,
  the row N11 mandates. Without it the mutation panics with `0x11` and the case passes for the
  wrong reason, never reaching the spread check it claims to exercise.

And one is the attack the whole design exists to stop: **decoding the submitted bytes instead of
the verified return**. A library reading its own input accepts whatever the caller wrote, which is
how an adversarial review settled a $1,000,000 BTC price from `fullReport = 0xdead`.

---

## §5 Real APIs only

Every external call is traced to the deployed contract rather than invented:

- `IVerifierProxy` is hand-written, four members, matched against the deployed proxy's behaviour at
  block 62922075 through two operators.
- Selectors derived with `cast sig`, not guessed: `verify(bytes,bytes)` `0xf7e83aee`,
  `s_feeManager()` `0x38416b5b`, `s_accessController()` `0x94ba2846`, `typeAndVersion()` `0x181f5a77`.
- The Data Streams REST API is called with Chainlink's documented HMAC scheme.

---

## §8 Finality

The cited block **62922075** was read through two providers, which returned the same number, hash and
timestamp. It is far below `finalized` on both: at the time of the run the head was near 64,979,000,
so the block sits roughly 2,057,000 blocks deep, and MonadBFT does not reorganise a finalized block.
The block hash is re-read on every probe run and any change fails it.

**This claim cites no on-chain event**, because a Data Streams report is off-chain signed bytes and
emits none, so §8's event and log-index clause does not apply to it.

---

## §9 Deployment identity

No deployment. The contract being **read** is identified before its answers are trusted: address
`0x72790f9eB82db492a7DDb6d2af22A270Dcc3Db64`, chain id 10143, `VerifierProxy 2.0.0`, 7,009 bytes of
runtime code, `s_feeManager` and `s_accessController` both zero, asserted on every probe run and in
the fork test.

---

## §11 Provider disagreement

The pair has different operators, recorded machine-readably in `script/providers.json` with a stable
identifier, the operator, archive and `finalized` support, and the rate-limit and failure domain.
Evidence names the pair it used and carries the sanitized resolved host; a run whose resolved host
does not match the approved record **fails before making any call**.

Failure behaviour is tested, not assumed. Verified on 2026-09-23:

| Scenario | Result |
|---|---|
| Two agreeing providers, diagnostic | `VERIFIED_MATCH`, exit 0 |
| `--as-proof` with an unknown-operator pair | `NOT_INDEPENDENT`, exit 4 |
| A provider that cannot serve the block | `ARCHIVE_UNAVAILABLE`, exit 3 |
| A host that is not the approved host | refused before any call, exit 2 |

`ARCHIVE_UNAVAILABLE` means **the affected Type B claim is unmet**. It is never a green bypass and it
can never retire a mandatory fixture.

---

## §13 Reproducing this

```
# offline, no network, no credentials
forge build --sizes
forge fmt --check
forge test -vvv
node script/build-cases.mjs --check
node script/rule-reference.mjs
node script/mutate-reference.mjs
node script/mutate-solidity.mjs

# Type B1, network, no credentials
MAKO_RPC_A=https://testnet-rpc.monad.xyz/ \
MAKO_RPC_B=https://rpc-testnet.monadinfra.com \
  node script/probe-archive.mjs --as-proof
```

Tool versions are recorded per run in the evidence files. Node is pinned by `.nvmrc`; the scripts are
dependency-free, Node built-ins only, so a clean checkout needs no install step.
