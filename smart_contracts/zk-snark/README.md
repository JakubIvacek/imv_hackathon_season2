# Media Voting — ZK-SNARK variant (DAML / Canton) — BUILT & PASSING

This is **variant 2 of 3**. It is **implemented, `daml build` + `daml test`
passing**. Siblings:

- [`../no-zk/`](../no-zk/) — variant 1, no privacy, built and passing.
- [`../canton-privacy/`](../canton-privacy/) — variant 3, Canton-native
  privacy, built and passing.

Privacy here comes from **Circom/snarkjs zero-knowledge proofs, generated and
verified off-ledger, with the verifier's boolean result attested on-ledger**.

## Why this variant is different from the other two

The other two variants only had to model DAML business logic. This one first
has to answer a hard architectural question: **DAML/Canton has no native
elliptic-curve pairing precompile.** The EVM has one — that's what lets a
Solidity Groth16 verifier check a zk-SNARK proof cheaply on-chain (what
`IZKVoteVerifier.sol` is a stub for). DAML is a contract-logic language, not a
circuit/crypto VM — it **cannot** execute a pairing check itself, and there is
no plan to add one.

**Consequence: this variant cannot be a trustless on-ledger verifier the way
the Solidity path is designed to be.** Trust must shift somewhere. Options:

1. **Bridge to a real Ethereum Groth16 verifier** and read the result into
   Canton. Rejected: reintroduces the Ethereum dependency the port exists to
   remove, and cross-chain bridging is a much larger problem — out of scope.
2. **Federated quorum** of N-of-M verifiers who must independently agree.
   Rejected *for this build* in favour of simplicity — it multiplies the party
   set, authorization plumbing, and test surface without changing the core
   tradeoff (you still trust parties, just more of them). It is the obvious
   hardening step, noted but not built.
3. **Off-ledger verification + on-ledger trust attestation** — **the chosen and
   implemented approach**: a single trusted `Verifier` party runs
   `snarkjs groth16 verify` off-ledger and submits an attestation contract onto
   Canton stating the proof for a given `voterHash`/`eventId`/`mediaId`
   verified successfully.

**Be upfront with judges:** a real on-chain zk-SNARK verifier needs **no**
trusted party at verification time; this Canton variant does. That is a real,
meaningful weakening of the guarantee `IZKVoteVerifier.sol` was designed to
provide. This variant is **"ZK proof generation + off-ledger verification +
on-ledger trust attestation"**, not "trustless on-ledger verification."

## What is actually built

`daml/MediaVoting.daml` implements these templates:

| Template | Role |
|---|---|
| `ZKProofSubmission` | Created by `Voter` (signatory), observed by `Verifier`. Carries only `proofBytes` + a `PublicSignals` record mirroring the circuits' public inputs (`pkAuth`, `subject`, `vote`, `reqCity`, `reqDistrict`, `hVC`) plus `eventId`/`mediaId`/`voterHash`. **Never** the private witness (vc_city, vc_district, signatures). Its `AttestProof` choice (controller `Verifier`) records the off-ledger verification result and, if valid, emits the attestation + nullifier. |
| `ZKVoteAttestation` | Created by `Verifier` after off-ledger `snarkjs` verification succeeds. Minimal disclosure: `support`, `isLocalVoter`, pseudonymous `voterHash`, `eventId`, `mediaId`. Same shape as `VoteAttestation` in `canton-privacy/`. Observed by the reporter agency; its `RedeemForTally` choice feeds the tally. |
| `ZKNullifier` | Double-vote prevention, keyed on `(verifier, reporterAgency, eventId, mediaId, voterHash)` — same pattern as `VoteNullifier` in `canton-privacy/`. |
| `NewsEvent` / `MediaItem` | Same structure/field names as the other two variants and the Solidity source. `TallyEventVote` / `TallyMediaVote` consume a `ZKVoteAttestation` and apply identical increment logic. |

`PublicSignals` is a plain record mirroring the circuits' declared public
inputs, so only public circuit values ever reach the ledger.

The off-ledger component is sketched (not runnable here) in
[`verifier-service/verify.md`](./verifier-service/verify.md): watch the ledger
for `ZKProofSubmission`s, call `snarkjs.groth16.verify(vkey, publicSignals,
proof)`, and exercise `AttestProof` as the `Verifier` party.

## What is real vs simulated

- **Real:** all DAML modelling — the templates, the observer scoping that hides
  the proof from the agency, the `AttestProof` authorization by the `Verifier`,
  the nullifier-key double-vote prevention, and the tally logic. All exercised
  by passing `daml test` scripts.
- **Simulated / mocked:** the actual Groth16 pairing check. DAML cannot run
  snarkjs, and this environment has no compiled proving/verification keys, so
  proof validity is passed into `AttestProof` as a `proofVerified : Bool`. This
  deliberately mirrors `MockZKVoteVerifier.sol` in the Solidity project, whose
  `verifyVoteProof` returns a settable `(voteValid, isLocalVoter)` instead of
  doing real pairing math. The DAML Script tests act as that off-ledger
  verifier: `proofVerified = True` for a "valid" proof (and `submitMustFail`
  with `False` for an "invalid" one).

## Circuits reused, unmodified

`../../../ZK-SNARKs/identity-verifier/IdentityCircuit.circom` and
`../../../ZK-SNARKs/location-verifier/LocationCircuit.circom`, compiled and
proved off-ledger with the standard Circom/snarkjs Groth16 toolchain.

## Constraint mapping (which check lives where)

Unlike `canton-privacy/`, the identity/locality constraints do **not** become
DAML `assert`s here — they are proven inside the circuit in zero knowledge and
are invisible to DAML. DAML only records the verifier's attested result and
prevents double-voting.

| Circuit constraint | Where it is checked in this variant |
|---|---|
| `authSigVerify` (EdDSA over the VC), `pkEq` (`address === vc_address`), `cityEq`, `districtEq`, `voteBool`, `vcHashEq` (`H_VC` matches Poseidon) | **Inside the Circom circuit**, proven in zero knowledge off-ledger. None become DAML asserts — DAML never sees the private fields. Their combined result is the single boolean returned by off-ledger `snarkjs groth16 verify`, passed into `AttestProof` as `proofVerified`. |
| `cityEq` + `districtEq` → `isLocalVoter` | Proven in ZK; the off-ledger verifier reports the resulting flag as `isLocalVoter` on `AttestProof` (mirrors the second return value of `MockZKVoteVerifier.verifyVoteProof`). |
| "Is this proof valid?" | The one thing DAML *acts on* — but only by trusting the `Verifier` party's `proofVerified` attestation, since DAML cannot run the pairing check. Mirrors Solidity `require(voteProofValid, "Invalid vote zk proof")`. **This is the load-bearing trust assumption of the whole variant.** |
| Solidity `mapping(bytes32=>bool) hasVoted` / ZK nullifier | `ZKNullifier` contract key — same idiomatic DAML pattern as the other two variants. |

## Build & test

Requires the DAML SDK (`daml` on `PATH`) and a JVM (11+/17) for the script
runner.

```bash
cd smart_contracts/zk-snark/
daml build
daml test
```

`daml test` runs four scripts, all passing:

- `happyPath` — a proof is submitted; the (mocked) verifier attests it valid;
  the reporter tallies it; counters update correctly on both a media-level and
  an event-level vote. Also asserts the agency never sees the
  `ZKProofSubmission`, only the `ZKVoteAttestation`.
- `invalidProofRejected` — `AttestProof` with `proofVerified = False` is
  rejected (mirroring `require(voteProofValid, ...)`), and no attestation /
  nullifier is written.
- `doubleVoteRejected` — a second `AttestProof` with the same `voterHash` on the
  same target collides with the `ZKNullifier` key and the ledger rejects it.
- `setup` — the shared fixture.

## Files

- `daml.yaml` — project config (SDK `2.10.4`, matches the siblings).
- `daml/MediaVoting.daml` — templates + trust-model header.
- `daml/Test.daml` — the four DAML Script tests above.
- `verifier-service/verify.md` — off-ledger verifier service design sketch
  (unimplemented; needs a live Canton ledger + compiled keys).
