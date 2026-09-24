# VERIFICATION: T0.1 and T1.1, the rounds settlement rule and MakoRoundsV1

**Corrected 2026-09-24 after the Codex diff review.** An earlier version of this record said the
shipping library was tested "against the real `VerifierProxy`" and that the verifier's identity was
asserted "in the fork test". **No fork test existed.** The only real-report row was skipped in Solidity
with a comment deferring it to that nonexistent test, and the B1 probe checked the verifier's code
LENGTH while recording, but never comparing, its hash. Both are now true: the fork test exists and
passes on two operators, and the probe gates on the code hash. This paragraph stays so the record does
not quietly rewrite what it previously claimed.

The record `PROOF_STANDARD.md` Version 3 §13 requires. Every claim below declares its **proof type**
per §0: **A** offline, **B1** direct `eth_call`, **B2** Foundry fork, **C** transaction.

**T0.1 produces Type A and Type B claims and no Type C claim.** That is not a gap: there is no rounds
deployment to transact against, and `INVARIANTS.md:45` requires this rule test to run before the
contract exists. The narrow pre-contract exception in `TASKS.md`, set by Joshua on 2026-09-23, defers
§2's settlement-answer computation and cross-check and §6's real transaction to T1.1, and both still
block deployment.

---

## Credential incident, 2026-09-23 to 2026-09-24

**An Alchemy API key was committed to this public repository.** On 2026-09-23 the archive probe was run
with a credentialed Alchemy endpoint. The probe stored its whole provider object, including the full
URL, in `evidence/archive-probe-2026-09-23T15-40-59-836Z/RESULT.json`, and that file was committed in
`ca7066c` and pushed. The Codex diff review (round 3) found the code path on 2026-09-24; by then the key
had been public for about a day.

Response:
- **Rotation of the key in the Alchemy dashboard (the "mako markets" app) is REQUIRED and, as of this
  commit, NOT YET CONFIRMED.** Until it is, the copy that remains in git history must be treated as live.
  History was not rewritten; rotation, not a rewrite, is what makes the leaked copy worthless.
- The committed file is redacted in place; every other copy was located by path and removed.
- **The probe can no longer write a URL.** URLs live in a module-private map that nothing serializes;
  the provider object written into evidence holds only id, host, operator and a non-secret config hash.
  `writeEvidence` refuses to write anything containing a configured URL's path or query (exit 5).
  `script/test-probe-redaction.mjs` runs the real probe against a local mock with sentinel tokens in
  the URL path and query, and proves they reach neither evidence nor console output, on the full run
  and the early-failure path, and that re-introducing the original bug is refused.
- **CI now fails on any credentialed endpoint or key-shaped value in a tracked file**
  (`script/check-no-secrets.mjs`, first step of the workflow), printing file and line, never the value.
  Shown to catch the leaked file itself in a clone of the commit that carried it.

That test also found an unrelated probe defect: a verifier return shorter than 288 bytes crashed the
decoder with no evidence written and no classification. It is now recorded as `VERIFICATION_MISMATCH`.

**Round 4 of the Codex diff review found the fix incomplete, one layer out.** The probe no longer WROTE a
URL, but it still PRINTED provider-controlled JSON-RPC error text verbatim to stdout, where a CI run
publishes it, before the evidence guard ever ran; a provider or proxy echoing the request URL would have
put the credential in a public log. And the secret scan exempted two tracked files by name. Now:
- **All provider text is untrusted and possibly secret-bearing.** Error messages are inspected transiently
  and reduced to a local category (`revert`, `not-served`, `rate-limited`, `provider-gas-limit`,
  `rpc-error`, `transport`) plus the numeric code; the text is never logged or stored. The raw response
  text is no longer returned from the RPC helper at all, only its hash. `typeAndVersion` is stored
  verbatim only when it equals the expected string, otherwise as a hash.
- **Every console write is scrubbed** of each configured URL, path and query, plain and hex-encoded, and
  uncaught errors are printed scrubbed; `writeEvidence` also refuses hex-encoded fragments.
- `test-probe-redaction.mjs` gains two HOSTILE providers: one echoing the credentialed URL in an HTTP-200,
  code-3 revert message, one echoing it in `typeAndVersion`. Both pass; **against the round-4 probe both
  fail with the credential leaked to stdout**, so the test would have caught it.
- `check-no-secrets.mjs` exempts no file. `test-check-no-secrets.mjs` injects runtime-built key-shaped
  values into each formerly exempt file and a new file, requires failure without printing the value, and
  requires a placeholder to pass; against the round-4 scanner the formerly exempt cases fail the test.

## What this proves

- **Type B2, the library against the real verifier.** `test/RoundSettlementFork.t.sol` forks Monad
  testnet at block 62922075, leaves Chainlink's `VerifierProxy` in place, and runs the mandatory real
  report through `RoundSettlement.check()`: accepted at its boundary with the widened window intact,
  rejected one second either side, rejected one second past `expiresAt` although the real verifier
  itself still accepts it, and rejected when a signed byte is flipped. The verifier's runtime keccak256
  is asserted against `SPEC.md:78`. Passed through QuickNode and through Monad Foundation.
- **Type B1, the verifier's answer directly.** `script/probe-archive.mjs` reads the proxy through two
  operators at that block, gates on its runtime code hash, and requires byte-identical returns.
- **Type A, everything else.** Return shapes the real verifier will not produce, driven by a mock
  placed at the pinned address; the 24-row case corpus evaluated by two independent implementations;
  and the whole of `MakoRoundsV1`: lifecycle, entry, exact-token semantics, fees, conservation,
  refunds, claims, treasury and reentrancy. No transaction has been sent to any chain.

## What this does not prove, and who owns it

| Not proven here | Owner |
|---|---|
| Any Type C claim: a real settlement transaction, read back against its report bytes (§6) | T1.1 on deployment; T2.0 for the keeper path |
| An independent cross-check of a settled answer against another oracle (§2) | T1.1, per the `TASKS.md` exception |
| `onReport`, the CRE delivery path: unbuilt until the forwarder's metadata layout is pinned | T2.0 |
| Deploy-script assertions on the USDC and verifier addresses and code hashes (N16, N22) | T1.1 deployment |
| Keeper liveness and censorship disclosure | T2.0 |
| Capacity at the maximum concurrent round count, which sets `MAX_ACTIVE_ROUNDS` | T0.1c |

Built on this branch and evidenced at Type A, so no longer on that list: the settlement outcome, the
round lifecycle, fees and conservation, refunds, claims and the treasury path.

**The future-observation rejection, stated precisely,** because the first version of this record
overstated it. On the public `settle` path a report from a future second is rejected by the library's
boundary check, as `WrongObservationTime`, and the contract's own `ObservationInFuture` guard is
UNREACHABLE: the library requires each observation to equal its boundary exactly, and `settle` requires
`block.timestamp >= closeTime`, so both observations are already at or before now. So the public-path
property is DERIVED from those two checks, both tested and mutated
(`test_FutureBoundaryReportIsRejectedAtTheBoundaryCheck`). The retained guard is defence in depth, proven
directly through a test harness (`test_FutureObservationGuardRejectsDirectly`) and by its own mutation.
The test that once claimed to prove it could not reach it; the Codex diff review caught that.

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
  `expiresAt` still returned 352 bytes at `latest`, and confirmed on the fork: one second past
  `expiresAt` the real verifier accepts the report and only the library's step 7 rejects it. SPEC §5.2
  step 7 is the only expiry defence anywhere in this system.
- **A full report is malleable, so its hash is not canonical.** Found by the fork suite on 2026-09-24.
  `rawVs` packs one recovery byte per signature and this report carries two, so bytes 194 to 223 are
  verified by nothing: changing one yields a different byte string that verifies to the IDENTICAL
  report (`test_UnusedSignaturePaddingIsMalleable`). Money and outcome are unaffected, since only the
  verified return is decoded (N26 holds). But `MakoRoundsV1` stores and emits `keccak256` of the
  SUBMITTED bytes, as SPEC §5.3 specifies, so a settler can make the on-chain evidence hash differ
  from the hash of the report as Data Streams serves it. A watchdog must match reports by their
  verified fields, never by that hash. Changing what is hashed would change the spec, so it is
  recorded here for a decision rather than changed.

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

### 1b. The verifier's answer, directly (Type B1, two distinct operators)

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
| Verifier code | runtime sha256 `246be742ffcc522f72309f1f42c77817af4d6f823969ce9e5763f2a9327ca231`, **GATED**: a mismatch is `VERIFICATION_MISMATCH`. Tied to `SPEC.md:78`'s keccak256 by computing both from the same bytes on both operators |
| Evidence | `evidence/archive-probe-2026-09-24T19-10-24-255Z/RESULT.json`, the first run that gates on the code hash; the 2026-09-23 runs checked length only |
| Command | `MAKO_RPC_A=… MAKO_RPC_B=… node script/probe-archive.mjs --as-proof` |

**The code-hash gate is proven to fail**, not only to pass: run with a wrong pinned hash, both
providers report `DOES NOT MATCH THE PIN` and the probe exits 3 with `VERIFICATION_MISMATCH`.

### 1c. The shipping library against the real verifier (Type B2, two distinct operators)

| | |
|---|---|
| Test | `test/RoundSettlementFork.t.sol`, 7 tests, env-guarded by `MAKO_FORK_RPC` |
| Fork | Monad testnet, block **62922075**, timestamp 1789529160, `--network monad` |
| Block hash | `0x73f54743…a722d6`, read from EACH provider through BLOCKHASH at block 62922076 and REQUIRED in `setUp`, so every test depends on the provider serving the pinned block. A wrong pin fails setUp; shown |
| Result | **7 passed** through QuickNode, **7 passed** through Monad Foundation, both serving the pinned hash |
| Evidence | `evidence/fork-b2-2026-09-24T20-49-26Z/`, with traces. The earlier `fork-b2-2026-09-24T19-13-30Z` run did not check the block hash and is marked superseded |
| `check()` gas | **88,695**, real verifier, cold access, against a 150,000 ceiling |

It includes `test_AcceptsWindowEndingAtBoundary`, the test `INVARIANTS.md:12` names, on the real
report it requires. **Offline CI SKIPS these tests, visibly, and a skipped test is not a passing one.**
The B2 claim rests on the recorded runs above, not on CI.

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

**The real row is evaluated against ONE pinned B1 record.** `CASES.json` pins the record and the vendored
fixture by path and SHA-256; the reference itself requires the record to be `VERIFIED_MATCH`,
`two-distinct-operators`, for block 62922075 with its hash and timestamp, with two byte-identical
returns. **And the record must be ABOUT that fixture:** the reference re-encodes
`verify(fullReport, "")` from the pinned fixture with its own encoder and requires the hash to equal the
record's `calldataSha256`, and requires the record to name the pinned fixture's path. Without that, a
renewal that replaced the fixture and re-pinned its checksum would still pass against an OLD B1 record,
and the new fixture would never have been verified; the Codex diff review (round 3) caught it. The pinned
record is `archive-probe-2026-09-24T21-28-43-466Z`, the first written after the probe stopped serializing
URLs, so it holds no endpoint URL at all. Anything else is a FAILURE of the real row and a non-zero exit, never a skip. The first version
took whichever archive-probe directory sorted last, so a later failed run silently dropped the mandatory
row while the gate still exited 0; the Codex diff review caught it. `script/test-rule-reference.mjs`
proves the new behaviour across ten scenarios, including both review sequences, and runs in CI.

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

**Solidity: 63 mutations, 63 killed, 0 survived.** Every one caught at RUNTIME by a named
test. Run 2026-09-24 against all three slices plus the adversarial-review fixes.

### `src/RoundSettlement.sol` (15 mutations)

| Clause | Mutation | Killed by |
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

### `src/MakoRoundsV1.sol` (48 mutations)

Round-level guards the library cannot make; entry and exact-token semantics; fee accounting; every path by
which money leaves; and the fixes from the adversarial pass.

| Clause | Mutation | Killed by |
|---|---|---|
| SPEC 3 lifecycle | allow settlement before closeTime | `test_SettleRevertsBeforeCloseTime`, `test_BoundariesHoldAtPlusMinusOne` |
| N13 | allow settlement at or after submitDeadline | `test_SettleAndRefundWindowsDisjoint`, `test_StuckRoundsHoldCapacityUntilSomeoneRefundsThem`, `test_BoundariesHoldAtPlusMinusOne` |
| SPEC 3 terminal states | allow a round to settle twice | `test_ARefundedRoundCannotThenSettle`, `test_RoundSettlesAtMostOnce`, `test_LastSecondSettleWinsAndIsFinal` |
| N25 | check the anchor against closeTime instead of startTime | `test_LastSecondSettleWinsAndIsFinal`, `test_TieEmitsItsSettlementEvidence`, `test_ARefundChargesNoFees`, +29 more |
| N1 | check the close against startTime instead of closeTime | `test_LastSecondSettleWinsAndIsFinal`, `test_TieEmitsItsSettlementEvidence`, `test_ARefundChargesNoFees`, +28 more |
| SPEC 5.3 | invert the outcome direction | `test_LastSecondSettleWinsAndIsFinal`, `test_ClaimIsNotReentrant`, `test_CreatorWhoWonGetsPayoutAndFeeInOneCall`, +7 more |
| SPEC 5.3 | settle a tie as UP instead of refunding | `test_TieEmitsItsSettlementEvidence`, `test_ARefundChargesNoFees`, `test_ARefundedRoundCannotThenSettle`, +5 more |
| N27 | drop the whole-minute boundary requirement | `test_StartTimeOnMinute` |
| SPEC 8 | drop the creator allowlist | `test_OnlyCreatorsMaySchedule` |
| SPEC 4 | drop the per-creator active-round limit | `test_OneNonTerminalRoundPerCreator` |
| SPEC 4, MAX_ACTIVE_ROUNDS | drop the global active-round cap | `test_GlobalActiveRoundCapIsEnforced`, `test_StuckRoundsHoldCapacityUntilSomeoneRefundsThem` |
| SPEC 4, MIN_LEAD | drop the minimum scheduling lead | `test_LeadBoundsAreEnforcedAtTheBoundaryPlusMinusOne` |
| N2, N25 | lock entries at startTime instead of ENTRY_LEAD before it | `test_PhasesFollowTheClockWithoutATransaction` |
| CREATORS_HASH canonicality | drop the strictly-ascending creator rule | `test_ConstructorRejectsAnUnsortedCreatorSet`, `test_ConstructorRejectsDuplicateCreators`, `test_ConstructorRejectsTheZeroAddressAsACreator`, +1 more |
| SPEC 4, TREASURY | accept a zero treasury | `test_ConstructorRejectsZeroTreasury` |
| SPEC 8 | accept an empty creator set | `test_ConstructorRejectsAnEmptyCreatorSet` |
| SPEC 3 terminal states | allow entry into a terminal round | `test_EntryIntoATerminalRoundReverts` |
| N2, N25 | allow entry at or after entryCloseTime | `test_EntryRevertsAtEntryClose`, `test_BoundariesHoldAtPlusMinusOne` |
| SPEC 4, MIN_ENTRY | drop the minimum entry | `test_EntryBelowTheMinimumReverts` |
| N12 | let one address take both sides | `test_OneAddressOneSide` |
| N22 | credit the requested amount rather than what arrived | `test_FeeOnTransferTokenReverts`, `test_OvershootingTokenReverts` |
| N22 | accept >= instead of == on the balance delta | `test_OvershootingTokenReverts` |
| N22 | ignore a false or malformed transfer return | `test_MalformedReturnTokenReverts` |
| N3, SPEC 5.2 per-submission, SPEC.md:135 | allow a one-sided round to settle | `test_OneSidedRoundCannotSettle` |
| SPEC 7 | charge the protocol fee on the smaller side instead of the total | `test_FeesFollowTheSpecFormula` |
| SPEC 7 | charge the creator fee on the total instead of the smaller side | `test_FeesFollowTheSpecFormula` |
| SPEC 7 conservation | leave the fees inside distributable | `test_CreatorWhoWonGetsPayoutAndFeeInOneCall`, `test_FeesFollowTheSpecFormula` |
| N3, settle/refund exclusivity | refund a two-sided round as OneSided | `test_FinalizeRefundAfterDeadline`, `test_TwoSidedRoundCannotRefundAsOneSided`, `test_BoundariesHoldAtPlusMinusOne` |
| N5, N13 | allow NoPrice before submitDeadline | `test_FinalizeRefundAfterDeadline`, `test_TwoSidedRoundCannotRefundAsOneSided`, `test_BoundariesHoldAtPlusMinusOne` |
| SPEC 3 terminal states | allow finalizeRefund on a terminal round | `test_ActiveIndexSurvivesOutOfOrderRemoval`, `test_FinalizeRefundOnATerminalRoundReverts`, `test_LastSecondSettleWinsAndIsFinal` |
| N6 | allow claiming before a terminal state | `test_ClaimBeforeTerminalReverts`, `test_SeedLocked` |
| SPEC 7, losers receive nothing | pay any entrant as if they won | `test_LoserClaimReverts` |
| N19 no double claim | never mark a stake claimed | `test_CreatorWhoWonGetsPayoutAndFeeInOneCall`, `test_NoDoubleClaim` |
| N19 creator fee once | never mark the creator fee claimed | `test_CreatorWhoWonGetsPayoutAndFeeInOneCall`, `test_ZeroStakeCreatorClaimsFee` |
| N19 fees only on SETTLED | pay the creator fee on a refunded round | `test_RefundRecordsNoCreatorFee` |
| N17 | sweep the remainder on the first winner, not the last | `test_RemainderWaitsForTheLastWinner` |
| SPEC 7, N17 | pay winners from the total instead of distributable | `test_ClaimIsNotReentrant`, `test_CreatorWhoWonGetsPayoutAndFeeInOneCall`, `test_NoDoubleClaim`, +2 more |
| N19 | let anyone withdraw the treasury | `test_TreasuryOnly` |
| N17, double spend | do not zero the treasury balance on withdrawal | `test_TreasuryOnly` |
| N8, N17 | ignore an outbound shortfall | `test_ShortOutboundTransferReverts` |
| N8 | remove the reentrancy guard | `test_ClaimIsNotReentrant`, `test_EnterIsNotReentrant`, `test_SettleIsNotReentrant`, +1 more |
| N17, N19 | do not accrue the protocol fee to the treasury | `test_SettleIsNotReentrant`, `test_TreasuryOnly`, `test_WithdrawTreasuryIsNotReentrant` |
| SPEC 5.1 | list rounds before closeTime as pending | `test_PendingSettlementListsOnlySettleableRounds` |
| SPEC 5.1 | list rounds past submitDeadline as pending | `test_PendingSettlementListsOnlySettleableRounds` |
| SPEC 5.1, SPEC.md:135 | list one-sided rounds as pending | `test_PendingSettlementExcludesOneSidedRounds` |
| SPEC 5.3, N14 | drop the tie evidence event | `test_TieEmitsEvidenceWithoutClaimingToBeSettled`, `test_TieEmitsItsSettlementEvidence` |
| N8, double settlement | remove the reentrancy guard from settle | `test_SettleIsNotReentrant` |
| SPEC 4, MAX_ACTIVE_ROUNDS, SPEC 5.1 | forget to remove a round from the active index | `test_ActiveIndexSurvivesOutOfOrderRemoval`, `test_PendingSettlementExcludesTerminalRounds`, `test_SettleIsNotReentrant`, +2 more |

**The adversarial pass** (an isolated agent given only the spec and the diff) found two defects, both now
fixed with their tests adopted into `test/Adversary.t.sol`: `pendingSettlement()` was missing although SPEC
§5.1 requires it, and a Tie stored its evidence without emitting it (SPEC §5.3, N14). It also raised as an
unproven suspicion that `settle` lacked `nonReentrant`; a re-entering verifier could have settled a round twice
and accrued the protocol fee twice. `settle` is now guarded and `test_SettleIsNotReentrant` proves it. Its
money attacks, including a 2,000-run cross-round solvency fuzz, all failed.

**What the runs found beyond the counts.**

- **One mutant survived the full sweep:** dropping `r.status == Status.Settled` from the creator-fee condition.
  A refunded round's `creatorFee` is always zero, so the mutant pays nothing extra and every balance stays right,
  which is why no balance assertion caught it. But it still sets the creator-fee flag, so `creatorFeeClaimed` would
  report a fee claimed on a round that never had one. `test_RefundRecordsNoCreatorFee` now asserts that flag and
  kills the mutant on its own. Balances were never the only thing that had to be true.
- The mutation swapping the anchor's boundary to `closeTime` was at first killed only by unrelated tests, never by
  `test_AnchorSecondIsStartTime`, which armed the anchor at `startTime ± 1` and passed regardless. It now also arms
  the anchor at `closeTime` and kills that mutation on its own.
- One sweep reported a mutation SKIPPED because its anchor matched twice. The runner refused to apply an ambiguous
  mutation rather than report a false kill. Every guard that shares a line with another is now tagged.
- One sweep's results were void because the source was edited while it ran. It was discarded and re-run clean.

### N7 and N10, which Solidity cannot prove

A test cannot enumerate a contract's functions, so a `test_NoSetters` could only check for the setters its author
thought of. `script/check-surface.mjs` instead asserts the compiled ABI: exactly six state-changing functions
(`claim`, `enter`, `finalizeRefund`, `schedule`, `settle`, `withdrawTreasury`), none payable, no fallback, and no
name implying pause, ownership, administration or upgrade. Verified to fail when a setter and a pause are added.
Its first run failed the REAL contract, because a case-insensitive setter pattern matched the `t` in `settle`; the
setter pattern is now case-sensitive.

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
runtime code identified by its hash (keccak256 against `SPEC.md:78` in the fork test, SHA-256 of the
same bytes in the probe), `s_feeManager` and `s_accessController` both zero. Before 2026-09-24 the probe
checked only the code length and no fork test existed; both gaps were found by the Codex diff review.

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

# Type B2, network, no credentials; run once per operator
MAKO_FORK_RPC=https://testnet-rpc.monad.xyz/     forge test --network monad --match-contract RoundSettlementFork -vvv
MAKO_FORK_RPC=https://rpc-testnet.monadinfra.com forge test --network monad --match-contract RoundSettlementFork -vvv
```

Tool versions are recorded per run in the evidence files. Node is pinned by `.nvmrc`; the scripts are
dependency-free, Node built-ins only, so a clean checkout needs no install step.
