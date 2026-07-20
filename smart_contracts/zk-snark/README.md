# Media Voting — ZK-SNARK variant (DAML / Canton) — PLANNED, NOT YET BUILT

This is **variant 2 of 3**. It is **not implemented** — this directory only
records the design so it can be picked up later without re-deriving it. See
sibling variants for the two that *are* built:

- [`../no-zk/`](../no-zk/) — variant 1, no privacy, built and passing.
- [`../canton-privacy/`](../canton-privacy/) — variant 3, Canton-native
  privacy, built and passing.

## Why this variant is different from the other two

The other two variants only had to model DAML business logic. This one has to
answer a hard architectural question first: **DAML/Canton has no native
elliptic-curve pairing precompile.** The EVM has one (that's what lets a
Solidity Groth16 verifier check a zk-SNARK proof cheaply on-chain, e.g. what
`IZKVoteVerifier.sol` is a stub for). DAML is a contract-logic language, not a
circuit/crypto VM — it cannot execute a pairing check itself, and there is no
plan to add one.

**Consequence: this variant cannot be a trustless on-ledger verifier the way
the Solidity path is designed to be.** It must shift trust somewhere. The two
options considered:

1. **Bridge to an actual Ethereum contract** that runs a real Groth16/Solidity
   verifier, and have Canton read the result. Rejected: reintroduces a
   dependency on Ethereum, which defeats the point of porting to Canton for
   the hackathon, and cross-chain bridging is its own hard (and much larger)
   problem — out of scope.
2. **Off-ledger verification + on-ledger trust attestation** (chosen approach,
   described below): run `snarkjs`/circom verification off-ledger — plain
   tooling, no blockchain of any kind involved — and have a trusted
   `Verifier` party submit an attestation contract onto Canton stating the
   proof for a given `voterHash`/`eventId`/`mediaId` verified successfully.

Option 2 is architecturally the same "trusted attestor" shape as the
`canton-privacy` variant's `Verifier` — except there the Verifier checks VC
fields directly in the clear, and here the Verifier's job is narrower: run an
external, deterministic verification program and truthfully report its
boolean result. **Be upfront with judges about this:** a real on-chain
zk-SNARK verifier (à la Ethereum) needs no trusted party at verification
time; this Canton variant does. That is a real, meaningful weakening of the
guarantee `IZKVoteVerifier.sol` was designed to eventually provide — this
variant is "ZK proof generation + off-ledger verification + on-ledger trust
attestation," not "trustless on-ledger verification."

## Planned design

Reuses the existing circuits unmodified:
`../../ZK-SNARKs/identity-verifier/IdentityCircuit.circom` and
`../../ZK-SNARKs/location-verifier/LocationCircuit.circom`, compiled and
proved off-ledger with the standard Circom/snarkjs toolchain (Groth16 proving
key, `snarkjs groth16 prove` / `snarkjs groth16 verify`).

### Parties

- `Voter` — holds a VC and generates a zk proof off-ledger using the Circom
  circuits, exactly as the circuits are designed today. Never puts the VC or
  its private fields on-ledger.
- `Verifier` — runs `snarkjs groth16 verify` off-ledger against the public
  verification key, then submits the on-ledger attestation. Analogous role to
  `IZKVoteVerifier` in Solidity, but implemented as a party's honest action
  instead of on-chain math.
- `ReporterAgency` / `reporter` — tallies attestations, same as the other two
  variants.

### Templates (planned, not implemented)

| Template | Sketch | Role |
|---|---|---|
| `ZKProofSubmission` | fields: `proofBytes : Text`, `publicSignals : [Int]` (or a typed record mirroring the circuits' public inputs — `pkAuth`, `address`, `vote`, `reqCity`, `reqDistrict`, `hVC`), `eventId`, `mediaId` | Created by `Voter`, observed by `Verifier`. Carries the proof + public signals only — never the private witness (vc_city, vc_district, signatures). |
| `ZKVoteAttestation` | fields: `support : Bool`, `isLocalVoter : Bool`, `voterHash`, `eventId`, `mediaId` | Created by `Verifier` after off-ledger `snarkjs` verification succeeds. Mirrors `VoteAttestation` in `canton-privacy/` almost exactly — same minimal-disclosure shape, different provenance (proof verification vs. direct field checks). |
| `ZKNullifier` | key `(verifier, reporterAgency, eventId, mediaId, voterHash)` | Same double-vote-prevention pattern as `VoteNullifier` in `canton-privacy/` and the vote-contract keys in `no-zk/`. |
| `NewsEvent` / `MediaItem` | same as the other two variants | Tally choices consume `ZKVoteAttestation`, identical increment logic to Solidity. |

### Interface mirroring `IZKVoteVerifier.sol`

A DAML `interface ZKVoteVerifier` mirroring the Solidity interface's two
methods conceptually:

- `verifyVoteProof` → the `Verifier`'s choice that checks a `ZKProofSubmission`
  against the off-ledger `snarkjs` result and, if valid, creates a
  `ZKVoteAttestation` (equivalent return: `isValid`, `isLocalVoter`).
- `verifyVCHashProof` → optional second choice if VC-hash verification is kept
  as a separate proof (as in the Solidity `zkVCHashCheckEnabled` toggle);
  otherwise fold into the single attestation choice, since the DAML model has
  no separate on/off toggle needed at the type level.

### Constraint mapping (same shape as `canton-privacy/`, different mechanism)

| Circuit constraint | Where it's checked in this variant |
|---|---|
| `authSigVerify`, `pkEq`, `cityEq`, `districtEq`, `voteBool`, `vcHashEq` | **Inside the Circom circuit itself**, proved in zero-knowledge off-ledger. Unlike `canton-privacy/`, none of these become DAML `assert`s — the whole point of this variant is that DAML never sees the private fields, only the proof + public signals. |
| Solidity `mapping(bytes32=>bool) hasVoted` / ZK nullifier | `ZKNullifier` contract key, same idiomatic DAML pattern as the other two variants. |
| "Is this proof valid" | The one thing DAML *does* check — but only by trusting the `Verifier` party's attestation, since DAML cannot itself run the pairing check. This is the load-bearing trust assumption of the whole variant. |

## What would need building if this is picked up later

1. Off-ledger tooling: a small script/service that takes a `ZKProofSubmission`,
   runs `snarkjs groth16 verify` against the compiled circuits' verification
   keys, and calls back into the ledger (via the DAML/Canton JSON API or
   Ledger API) as the `Verifier` party to submit the attestation.
2. The DAML templates/interface above, `daml.yaml`, and DAML Script tests
   (happy path, invalid-proof rejection, double-vote rejection) — matching the
   test style already used in `no-zk/` and `canton-privacy/`.
3. A README section (like this one, expanded) making the trust tradeoff
   explicit for hackathon judges, since it's the most easily
   oversold/misunderstood part of this variant.
