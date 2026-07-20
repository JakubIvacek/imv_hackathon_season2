# Manual test plan — all three variants (via Navigator)

**Status: ✅ Complete.** Every item below was exercised live against a real
running Canton sandbox (via Daml Script and/or direct JSON API queries), not
just planned or eyeballed. See the summary table and per-item evidence below.

A plan for manually testing what we already automated in `daml test`, but by
hand in Daml Navigator — the same kind of walkthrough we just did for
`no-zk`, extended to all three variants. Nothing here is implemented as
code; it's a checklist to work through.

## Summary — what was verified

| Variant | Vote / attest happy path | Duplicate-vote rejection | Privacy claim (if any) | Other rejections checked |
|---|---|---|---|---|
| **no-zk** | Alice & Bob vote independently on `MediaItem`; `NewsEvent` tallies independently of `MediaItem` | Same `voterHash` reused → ledger rejects (contract-key collision) | **None (by design)** — confirmed Bob, a mere observer, can read Alice's full vote in cleartext (voter, voterHash, support) | — |
| **canton-privacy** | `Verifier` attests a matching VC → `VoteAttestation` + `VoteNullifier`; `ReporterAgency` tallies it, counts increment | Same `voterHash` re-attested on same target → rejected (`VoteNullifier` key collision) | **Verified directly**: `ReporterAgency`'s query for `VerifiableCredential` returns empty before *and* after tallying | Wrong `votingParty` → rejected (`pkEq` assert); city/district mismatch → `isLocalVoter=False` as a **soft flag**, not a rejection |
| **zk-snark** | `Verifier` attests a valid (mocked) proof → `ZKVoteAttestation` + `ZKNullifier`; `ReporterAgency` tallies it, counts increment | Same `voterHash` re-attested on same target → rejected (`ZKNullifier` key collision) | **Verified directly**: `ReporterAgency`'s query for `ZKProofSubmission` returns empty before *and* after tallying | Mocked invalid proof (`proofVerified=False`) → rejected, no attestation/tally created |

All three variants' "no other party can see the private contract" claims
were confirmed by directly querying the ledger as the reporter/agency party
and asserting the private template's result set was empty — not inferred
from the `signatory`/`observer` declarations alone.

## Prerequisites (apply to all three)

- `./run-demo.sh <variant>` boots the sandbox + Navigator with demo parties
  and starter data already loaded (fixed: `navigator-options:
  --feature-user-management false` in each `daml.yaml`, otherwise the login
  picker is empty).
- Only one variant can run at a time (same ports); stop the previous one's
  `canton.jar` / `navigator server` / `json-api` processes before starting
  the next.
- Things learned from the `no-zk` session, true for all variants:
  - Every vote/tally choice **archives and recreates** the contract it
    updates (new contract ID each time) — expected, not a bug.
  - Vote dedup keys are `(..., voterHash)`, not tied to the submitting
    party — reusing a `voterHash` fails even from a different party.
  - Give each test voter a distinct `voterHash` string
    (`"alice-vote-1"`, `"bob-vote-1"`, etc.).

## 1. `no-zk` — no privacy baseline

Parties: `Reporter`, `Alice`, `Bob`. Starter data: one `NewsEvent` +
`MediaItem` ("Flooding in Riverside District").

- [x] Log in as `Reporter`, confirm the starter `NewsEvent`/`MediaItem` are
      visible. **Verified programmatically via JSON API `/v1/query` as
      `Reporter`: 2 contracts returned (`NewsEvent`, `MediaItem`).**
- [x] Log in as `Alice`, exercise `VoteOnMedia` (`support = True`,
      `isLocalVoter = True`, `voterHash = "alice-vote-1"`). Confirm the
      `MediaItem`'s `yesCount`/`localYesCount` increment by 1 on the new
      contract. **Verified via Daml Script against the live ledger
      (`LiveScenarios:aliceVotesOnMedia`): starter `MediaItem` went from
      `yesCount=0, localYesCount=0` to `yesCount=1, localYesCount=1` on the
      new contract, with `noCount`/`localNoCount` unchanged.**
- [x] Retry the exact same `VoteOnMedia` call (same `voterHash`) as `Alice`.
      Confirm it's **rejected** by the ledger (contract-key collision).
      **Verified via Daml Script (`LiveScenarios:aliceDuplicateVoteRejected`):
      `submitMustFail` with `voterHash = "alice-vote-1"` again succeeded in
      catching the expected failure — the ledger rejected the second
      `MediaVote` create due to the `(reporter, eventId, mediaId, voterHash)`
      key collision.**
- [x] Log in as `Bob`, vote with a different hash (`"bob-vote-1"`), confirm
      it succeeds and tallies increment again. **Verified via Daml Script
      (`LiveScenarios:bobVotesOnMedia`): Bob voted `support = False,
      isLocalVoter = False`; `MediaItem` went from `yesCount=1, noCount=0`
      to `yesCount=1, noCount=1` (localYesCount/localNoCount unchanged, as
      expected for a non-local no vote).**
- [x] Try `VoteOnEvent` on the `NewsEvent` itself (either party), confirm its
      own tallies update independently of the `MediaItem`'s. **Verified via
      Daml Script (`LiveScenarios:voteOnEventIndependentTally`): Alice voted
      yes/local and Bob voted no/non-local on the `NewsEvent`, taking it from
      `yesCount=0, noCount=0, localYesCount=0, localNoCount=0` to
      `yesCount=1, noCount=1, localYesCount=1, localNoCount=0`; the starter
      `MediaItem`'s tallies (`yesCount=1, noCount=1` from the prior two
      items) were confirmed unchanged by these event-level votes.**
- [x] Confirm (visually, in Navigator) that **any** logged-in party can read
      the vote's contents (voter Party, `voterHash`, `support`) — this is
      the "no privacy" property being demonstrated, not a bug to fix.
      **Verified programmatically via Daml Script
      (`LiveScenarios:bobSeesAliceVoteContents`): `Bob` (a `community`
      observer, neither the reporter/signatory nor the voter) queried
      `MediaVote`/`EventVote` as himself and saw Alice's full vote contents
      in cleartext — `voter`, `voterHash = "alice-vote-1"`/`"alice-event-vote-1"`,
      `support = True`, `isLocalVoter = True` — confirming no confidentiality
      on vote contracts in this baseline variant.**

## 2. `canton-privacy` — Canton-native privacy

Parties: `Issuer`, `Voter`, `Verifier`, `ReporterAgency`. Starter data: one
`NewsEvent` + `MediaItem`, plus one `VerifiableCredential` (already created
by `Setup.daml`, signed by `Issuer`+`Voter`, observed by `Verifier`).

- [x] Log in as `ReporterAgency` first. Confirm the `NewsEvent`/`MediaItem`
      are visible, but the `VerifiableCredential` is **not** — this is the
      core privacy claim to verify, not just assume. **Verified
      programmatically: `ReporterAgency`'s `/v1/query` over all three
      templates returned only `NewsEvent`+`MediaItem` (2 contracts, 0
      `VerifiableCredential`); `Verifier`'s query over the same ledger
      returned the `VerifiableCredential` in full (city, district,
      voterHash).**
- [x] Log in as `Verifier`. Confirm the `VerifiableCredential` **is**
      visible (as an observer). Exercise `VerifyAndAttest` on it with a
      plausible `eventId`/`mediaId`, matching `reqCity`/`reqDistrict`
      (should yield `isLocalVoter = True`), and `votingParty = Voter`.
      Confirm it produces a `VoteAttestation` + `VoteNullifier`. **Verified
      via Daml Script against the live ledger (`LiveScenarios:item2_verifyAndAttest`):
      `Verifier`'s query found exactly 1 `VerifiableCredential` (city=Riverside,
      district=North, voterHash=demo-voter-hash-001); exercised `VerifyAndAttest`
      with `reqCity="Riverside"`, `reqDistrict="North"`, `votingParty=Voter` →
      produced a `VoteAttestation` with `support=True`, `isLocalVoter=True`,
      `voterHash="demo-voter-hash-001"`, plus a `VoteNullifier` keyed on
      `(Verifier, ReporterAgency, eventId=1, mediaId=None, voterHash)` (query
      confirmed exactly 1 `VoteNullifier` afterward).**
- [x] Log in as `ReporterAgency` again. Confirm the new `VoteAttestation` is
      now visible, but still contains **no** VC fields (only `support`,
      `isLocalVoter`, `voterHash`). Exercise `TallyEventVote` or
      `TallyMediaVote` on it, confirm the event/media tallies increment.
      **Verified via Daml Script (`LiveScenarios:item3_tallyWithoutVC`):
      `ReporterAgency`'s `query @VerifiableCredential` returned `[]` both
      before and after tallying; `query @VoteAttestation` returned exactly 1
      contract with only `support=True`, `isLocalVoter=True`,
      `voterHash="demo-voter-hash-001"` (no VC fields). Exercised
      `TallyEventVote` on the starter `NewsEvent` (eventId=1) → resulting
      `NewsEvent` had `yesCount=1`, `noCount=0`, `localYesCount=1`,
      `localNoCount=0` (up from all-zero).**
- [x] As `Verifier`, retry `VerifyAndAttest` with the **same** `voterHash`
      on the same target. Confirm it's rejected (`VoteNullifier` key
      collision). **Verified via Daml Script (`LiveScenarios:item4_doubleAttestRejected`),
      run after item 2 had already created the nullifier for
      `voterHash="demo-voter-hash-001"` on `(eventId=1, mediaId=None)`:
      `submitMustFail` on a second `VerifyAndAttest` with the same VC/voterHash
      and the same `eventId`/`mediaId` succeeded in asserting failure — the
      ledger rejected the transaction (`VoteNullifier` contract-key collision),
      exactly as `no-zk`'s dedup-key pattern predicts.**
- [x] As `Verifier`, retry `VerifyAndAttest` with `votingParty` set to a
      party other than the VC's actual `voter`. Confirm it's rejected
      (`pkEq` assert failure). **Verified via Daml Script
      (`LiveScenarios:item5_wrongVotingPartyRejected`): exercising
      `VerifyAndAttest` on the starter VC (whose `voter` is `Voter`) with
      `votingParty = Issuer` (a fresh target, `mediaId = Some 1`, to avoid
      colliding with the item-4 nullifier) was asserted via `submitMustFail`
      to fail — the ledger rejected it on the `"VC subject does not match
      the voting party (pkEq)"` assertion in `VerifyAndAttest`.**
- [x] As `Verifier`, try a VC whose `city`/`district` don't match the
      event's required values. Confirm the attestation still succeeds but
      with `isLocalVoter = False` (soft flag, not a hard rejection).
      **Verified via Daml Script (`LiveScenarios:item6_cityMismatchSoftFlag`):
      created a SECOND `VerifiableCredential` (city="Lakeside",
      district="South", voterHash="demo-voter-hash-002-mismatch") without
      touching the starter VC, so `Verifier` now holds 2 `VerifiableCredential`
      contracts. Exercising `VerifyAndAttest` against it with
      `reqCity="Riverside"`/`reqDistrict="North"` (the event's actual
      requirements) succeeded (no assertion failure) and produced a
      `VoteAttestation` with `support=True` but `isLocalVoter=False`.
      Tallying it onto the starter `MediaItem` incremented `yesCount` by 1
      while `localYesCount` stayed unchanged — confirming the mismatch is a
      soft flag, not a rejection.**

## 3. `zk-snark` — off-ledger-verified proof, on-ledger attestation

Parties: `Voter`, `Verifier`, `ReporterAgency`. Starter data: one
`NewsEvent` + `MediaItem`, plus one `ZKProofSubmission` (created by
`Setup.daml`, signed by `Voter`, observed by `Verifier`).

- [x] Log in as `ReporterAgency` first. Confirm the `NewsEvent`/`MediaItem`
      are visible, but the `ZKProofSubmission` (proof bytes + public
      signals) is **not**. **Verified programmatically: `ReporterAgency`'s
      `/v1/query` over all three templates returned only
      `NewsEvent`+`MediaItem` (2 contracts, 0 `ZKProofSubmission`);
      `Verifier`'s query over the same ledger returned the
      `ZKProofSubmission` in full (proofBytes, voterHash).**
- [x] Log in as `Verifier`. Confirm the `ZKProofSubmission` is visible.
      Exercise `AttestProof` with `proofVerified = True` (standing in for a
      real off-ledger `snarkjs groth16.verify()` call) and
      `isLocalVoter = True`. Confirm it produces a `ZKVoteAttestation` +
      `ZKNullifier`. **Verified via Daml Script against the live ledger
      (`LiveScenarios:attestValidProof`): `Verifier`'s query found the
      starter `ZKProofSubmission` (voterHash=demo-voter-hash-001,
      eventId=1, mediaId=Some 1); exercised `AttestProof` with
      `proofVerified=True`, `isLocalVoter=True` → produced exactly 1
      `ZKVoteAttestation` (support=True, isLocalVoter=True,
      voterHash="demo-voter-hash-001") and exactly 1 `ZKNullifier` keyed on
      `(Verifier, ReporterAgency, eventId=1, mediaId=Some 1,
      voterHash="demo-voter-hash-001")`.**
- [x] Log in as `ReporterAgency` again, confirm the `ZKVoteAttestation` is
      now visible (outcome only, no proof bytes), tally it, confirm counts
      increment. **Verified via Daml Script
      (`LiveScenarios:tallyValidAttestation`): before tallying,
      `ReporterAgency`'s query over `ZKProofSubmission` returned 0 contracts
      (confirming proof bytes never reached the agency) while the
      `ZKVoteAttestation` from the previous step was visible with only
      `support`/`isLocalVoter`/`voterHash`/`eventId`/`mediaId` fields (no
      proof, no VC, no voter party). `MediaItem(eventId=1, mediaId=1)` before
      tally: `yesCount=0, localYesCount=0`. Exercised `TallyMediaVote` as
      `ReporterAgency` → `yesCount=1, localYesCount=1` on the new contract;
      the `ZKVoteAttestation` was consumed (0 remaining afterward,
      `RedeemForTally` is consuming); `ZKProofSubmission` count for
      `ReporterAgency` remained 0 after tallying too.**
- [x] As `Verifier`, exercise `AttestProof` on a **new** submission with
      `proofVerified = False` (the mocked "invalid proof" case). Confirm no
      `ZKVoteAttestation`/tally update results — this is standing in for a
      real proof failing `snarkjs` verification. **Verified via Daml Script
      (`LiveScenarios:attestInvalidProofRejected`): created a fresh
      `ZKProofSubmission` (voterHash="invalid-proof-voter-hash-001",
      eventId=1, mediaId=Some 1); `submitMustFail` on `AttestProof` with
      `proofVerified=False` succeeded in asserting failure — rejected on
      `"off-ledger snarkjs verification reported the proof INVALID"`.
      `ZKVoteAttestation` count for `ReporterAgency` stayed at 0 before and
      after; `ZKNullifier` count for this voterHash stayed at 0; the
      un-attested submission was confirmed still active afterward
      (1 `ZKProofSubmission` matching that voterHash).**
- [x] As `Verifier`, retry `AttestProof` with the same `voterHash` on the
      same target as an already-attested submission. Confirm it's rejected
      (`ZKNullifier` key collision) — same dedup pattern as the other two
      variants. **Verified via Daml Script
      (`LiveScenarios:duplicateVoterHashRejected`), run after the earlier
      `attestValidProof` step had already created the nullifier for
      `voterHash="demo-voter-hash-001"` on `(eventId=1, mediaId=Some 1)`:
      created a SECOND, distinct `ZKProofSubmission` reusing that exact
      voterHash + target; confirmed exactly 1 existing `ZKNullifier` for
      that voterHash beforehand; `submitMustFail` on `AttestProof` (even
      with `proofVerified=True`) succeeded in asserting failure — the
      ledger rejected the transaction on the `ZKNullifier` contract-key
      collision `(Verifier, ReporterAgency, eventId=1, mediaId=Some 1,
      voterHash="demo-voter-hash-001")`. `ZKNullifier` count for that
      voterHash remained exactly 1 after the rejected retry, and
      `ZKVoteAttestation` count for that voterHash remained 0 (the earlier
      one having already been consumed by tallying).**

## Notes for whoever runs this

- Tests 1–3 each roughly mirror what `daml test` already checks
  automatically (see each variant's `daml/Test.daml`) — this plan exists so
  the same behavior can be *shown*, live, in a browser, for a demo/judging
  session, not because the automated tests are insufficient.
- If any step behaves differently than described here, that's either a
  genuine bug or a place where this plan's assumptions about Navigator/DAML
  behavior are wrong — worth flagging either way before a live demo.

## Operational gotchas found while running this live

- **Rebuild-after-boot package mismatch**: if you add or change a Daml
  Script module (e.g. `LiveScenarios.daml`) *after* `daml start` has already
  run `init-script`, the freshly rebuilt DAR gets a new package-id, and
  scripts run against it can't see the contracts created under the old
  package-id (`Setup:init`'s starter data becomes invisible — queries come
  back empty). Fix: have every script file in place *before* the first
  `daml start` boot for a given session.
- **`daml start` backgrounded via `nohup ... &` can die silently**: its
  interactive "press 'r' to rebuild" prompt reads stdin, and with no
  controlling TTY that read hits immediate EOF, which kills the underlying
  `canton.jar` process — while `navigator`/`json-api` keep running and
  reporting healthy (`/readyz` still returns 200), so it *looks* up but the
  ledger is gone (`daml script` fails with `Connection refused`). Fix: pipe
  stdin from something that never EOFs, e.g. `daml start < <(tail -f
  /dev/null)`.
- Running three `daml start` instances in parallel (one per variant) is
  fine on distinct ports, but is real resource pressure — one run saw a
  Canton sandbox die with no shutdown log or OOM trace, requiring a restart.
  If re-running all three at once, keep an eye out for this.
