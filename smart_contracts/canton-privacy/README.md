# Media Voting — Canton-native privacy (DAML / Canton)

A DAML port of the media / news-event credibility voting platform, targeting
Canton. This is **variant 3 of 3**: privacy **without cryptography**, achieved
with Canton's native sub-transaction (signatory/observer) privacy model plus a
trusted `Verifier` party that checks eligibility/locality rules in the clear.

Source of truth for the data model:
`../../media-voting-smart-contract/src/MediaVoting.sol`.
The rules being replaced come from the Circom circuits in
`../../ZK-SNARKs/identity-verifier/IdentityCircuit.circom` and
`../../ZK-SNARKs/location-verifier/LocationCircuit.circom`.

Sibling variants:

- `../no-zk/` — variant 1, the naive **no-privacy** baseline. Every vote is a
  ledger contract visible to the reporter and the whole community.
- zk-SNARK variant — variant 2 (separate future task). Eligibility/locality are
  proven in zero knowledge; the VC never touches the ledger and no party is
  trusted to read it.

## What a judge should look at first

1. `daml/MediaVoting.daml`, the `VerifiableCredential` template and its
   `VerifyAndAttest` choice. Every check inside it is tagged with a
   `-- [circuit: ...]` comment naming the exact Circom constraint it replaces.
2. The **stakeholder lines**: `VerifiableCredential` is `signatory issuer, voter`
   / `observer verifier` — those three parties are the *only* ones who can ever
   see the VC on a real Canton network. `VoteAttestation` is
   `signatory verifier` / `observer reporterAgency` and carries only the vote
   outcome + a pseudonymous `voterHash`.
3. `happyPath` in `daml/Test.daml`, which asserts the agency's ledger view never
   contains the `VerifiableCredential` (privacy assertions 1 and 2).

## How privacy works here (the tradeoff)

Privacy is **structural, not cryptographic**:

- **Who can see a contract** is decided by Canton's signatory/observer model. The
  raw VC (city, district, subject address, metadata) lives on a contract whose
  only stakeholders are the `Issuer`, `Voter` and `Verifier`. No other
  participant node — crucially **not** the reporter/agency — receives or stores
  it. On Ethereum all of those fields would be public.
- A trusted **`Verifier`** reads the VC, runs the business-rule checks in the
  clear, and emits a narrow `VoteAttestation` containing **only** `support`,
  `isLocalVoter` and a pseudonymous `voterHash` — never the voter's Party, city
  or district. The agency tallies attestations and never sees a VC.

**Tradeoff vs zk-SNARKs:** far simpler (no trusted setup, no circuits, no
proving/verifying keys) but it requires **trusting the Verifier party** at check
time and Canton's guarantee that non-stakeholders never receive the VC. A
zk-SNARK needs no trusted party when the proof is verified.

## Circuit constraint ↔ DAML check mapping

Each Circom constraint is re-expressed as an ordinary DAML `assert` / type / key
check. All of these live in `VerifyAndAttest` unless noted.

| Circuit constraint (Circom) | Purpose | DAML replacement |
|---|---|---|
| `authSigVerify` — `EdDSAPoseidonVerifier` over `Poseidon(vc_address, vc_city, vc_district, vc_metadata)` (both circuits) | Prove a trusted Authority (`pk_auth`) signed the VC | **Structural, not cryptographic:** `issuer` is a **signatory** of `VerifiableCredential`. The contract cannot exist unless the real Issuer party co-signed it. "Prove a signature" → "have the actual signer be a ledger party." No Poseidon, no EdDSA. |
| `pkEq` — `address === vc_address` (both circuits) | The on-chain voter is the VC subject | `assertMsg (votingParty == voter)` |
| `cityEq` — `vc_city === req_city` (LocationCircuit) | Voter is in the required city | part of `isLocalVoter = (city == reqCity) && ...` (soft flag, not a rejection) |
| `districtEq` — `vc_district === req_district` (LocationCircuit) | Voter is in the required district | part of `isLocalVoter = ... && (district == reqDistrict)` |
| `voteBool` — `vote*(vote-1) === 0` (LocationCircuit) | Vote is 0/1 | **Constructively unnecessary:** `support : Bool` cannot hold anything but `True`/`False`; the type system enforces it. Asserted trivially only to make the mapping explicit. |
| `vcHashEq` — `H_VC === Poseidon(...)` (LocationCircuit) | Bind the nullifier to the VC | The VC's `voterHash` field is bound to the contract by the co-signing Issuer/Voter; no recomputation needed. |
| nullifier / `H_VC` de-dup (ZK) **and** Solidity `mapping(bytes32=>bool) hasVoted` | Prevent double voting under one VC | Persistent `VoteNullifier` template with contract **key** `(verifier, reporterAgency, eventId, mediaId, voterHash)`. A colliding second `create` is rejected by the ledger — exactly `require(!hasVoted[...])`. |

## Templates

| Template | Signatories / observers | Role |
|---|---|---|
| `VerifiableCredential` | sig `issuer, voter`; obs `verifier` | The private VC. Only these three parties ever see it. Holds `city`, `district`, `subjectAddress`, `metadata`, `voterHash`. |
| `VoteAttestation` | sig `verifier`; obs `reporterAgency` | Minimal-disclosure output: `support`, `isLocalVoter`, `voterHash`, `eventId`, `mediaId` only. Consumed once when tallied. |
| `VoteNullifier` | sig `verifier` | Persistent de-dup record keyed on `(verifier, reporterAgency, eventId, mediaId, voterHash)`. Carries no vote content. |
| `NewsEvent` | sig `reporter` | Event + event-level tallies. `TallyEventVote` consumes an attestation and applies the Solidity increment logic. No `community` observer — individual votes are never on the agency's ledger, only aggregate tallies. |
| `MediaItem` | sig `reporter` | Media item + tallies. `TallyMediaVote` consumes a media-level attestation. |

Vote-increment logic matches the Solidity contract exactly: `support` adds to
`yesCount` (else `noCount`); when `isLocalVoter` is `True` it additionally adds
to `localYesCount` / `localNoCount`.

### Flow

```
Issuer + Voter ──create──▶ VerifiableCredential (Verifier observes)
                                   │
        Verifier ──VerifyAndAttest─┤  (pkEq, boolean, city/district → isLocalVoter,
                                   │   nullifier de-dup)
                                   ├──create──▶ VoteNullifier   (persistent de-dup)
                                   └──create──▶ VoteAttestation (support/isLocalVoter/voterHash)
                                                     │
              Reporter ──TallyEventVote/TallyMediaVote (RedeemForTally)──▶ updated tally
```

## Build & test

Requires the DAML SDK (`daml` on `PATH`) and a JVM (JRE 11+ / 17) for the script
runner.

```bash
# from this directory (daml-media-voting/canton-privacy/)
daml build      # compiles to .daml/dist/media-voting-canton-privacy-0.1.0.dar
daml test       # runs the Daml Script tests in daml/Test.daml
```

### Tests (`daml/Test.daml`)

- **`happyPath`** — Issuer+Voter create a VC; the Verifier attests a media-level
  YES vote and an event-level YES vote; the reporter tallies both and every
  counter matches the Solidity rules. **Asserts twice** that the agency's ledger
  view contains no `VerifiableCredential`, only the `VoteAttestation`.
- **`nonLocalVoter`** — a VC whose city/district do not match the event's
  required city/district yields `isLocalVoter = False` (a soft flag): the vote
  counts globally (`yesCount +1`) but not locally (`localYesCount` stays 0).
- **`doubleVoteRejected`** — a second `VerifyAndAttest` with the same `voterHash`
  on the same target is rejected (`submitMustFail`) by the colliding
  `VoteNullifier` key.
- **`subjectMismatchRejected`** — attesting with `votingParty = bob` against
  Alice's VC fails the `pkEq` assert (a VC cannot be used to vote as someone
  else).

All scripts pass under SDK 2.10.4.

### Design decisions / tradeoffs

- **`reporter` == the tally-holding agency.** The Solidity `reporter` and the
  "ReporterAgency" role are the same party here; the privacy guarantee is that
  this party is deliberately *not* a stakeholder of the VC.
- **Attestation is consumed at tally, de-dup is a separate persistent
  nullifier.** Consuming the attestation prevents double-*counting* the same
  attestation; the persistent `VoteNullifier` prevents a voter from being
  attested twice. Splitting the two keeps each concern single-purpose.
- **`VerifyAndAttest` is nonconsuming** so one long-lived credential can back
  votes on many events / media items (the nullifier key, which includes the
  target, is what stops re-voting the *same* target).
- **Locality is a soft flag, not a hard rejection**, matching the Solidity
  `isLocalVoter` semantics (non-local votes still count globally).
- **Verifier is sole controller of `VerifyAndAttest`.** In a fuller model the
  `voter` would co-authorize to prove intent; this is noted in the code.
