# Media Voting on Canton / DAML

DAML ports of the media / news-event credibility voting platform originally
built in Solidity for Ethereum
(`../media-voting-smart-contract/src/MediaVoting.sol`), targeting Canton for a
hackathon. Reporters publish `NewsEvent`s, each containing one or more
`MediaItem`s; community members vote yes/no on the credibility of an event and
of each media item; votes are deduplicated using a `voterHash` derived from a
Verifiable Credential (VC); global and "local" (`isLocalVoter`) tallies are
tracked separately.

Three variants exist side by side so judges can compare privacy approaches
directly. All three preserve the same field names and vote-increment semantics
as the Solidity source.

## Variants

| # | Directory | Privacy mechanism | Status |
|---|---|---|---|
| 1 | [`no-zk/`](./no-zk/) | None — deliberate naive baseline | ✅ Built, `daml build` + `daml test` passing |
| 2 | [`zk-snark/`](./zk-snark/) | Circom/snarkjs zero-knowledge proofs, verified off-ledger with an on-ledger trust attestation | ✅ Built, `daml build` + `daml test` passing (Groth16 check mocked — see below) |
| 3 | [`canton-privacy/`](./canton-privacy/) | Canton native sub-transaction privacy (signatory/observer scoping) + a trusted `Verifier` party checking rules in the clear | ✅ Built, `daml build` + `daml test` passing |

### 1. No-ZK baseline (`no-zk/`)

Every vote is a full ledger contract visible to the reporter and the whole
community observer list. `voterHash` is used only for deduplication via a DAML
contract key — there is no privacy protection at all. This is the transparent
contrast point for the other two variants.

### 2. ZK-SNARK variant (`zk-snark/`, built and passing)

Reuses the existing Circom circuits at
`../ZK-SNARKs/identity-verifier/IdentityCircuit.circom` and
`../ZK-SNARKs/location-verifier/LocationCircuit.circom`, proved off-ledger.
**Important caveat, see `zk-snark/README.md` for the full writeup:** Canton/
DAML has no native elliptic-curve pairing precompile (unlike the EVM), so DAML
cannot verify the proof itself. A single trusted `Verifier` party runs
`snarkjs groth16 verify` off-ledger and submits an on-ledger `ZKVoteAttestation`
— meaningfully weaker than a real on-chain zk-SNARK verifier, which needs no
trusted party at verification time (a federated-quorum alternative was
considered and rejected for this build in favour of simplicity). Implemented
templates: `ZKProofSubmission`, `ZKVoteAttestation`, `ZKNullifier`, plus
`NewsEvent`/`MediaItem`. Because this environment has no compiled proving/
verification keys and DAML cannot run snarkjs, the Groth16 pairing check itself
is **mocked** in tests (proof validity passed in as a `Bool`, mirroring
`MockZKVoteVerifier.sol`); the off-ledger service is sketched in
`zk-snark/verifier-service/verify.md`.

### 3. Canton-native privacy (`canton-privacy/`)

Replaces the ZK circuits' math with Canton's built-in contract-visibility
model: the VC lives on a contract whose only stakeholders are the `Issuer`,
`Voter`, and a trusted `Verifier` — no other party, including the reporter
agency, ever receives it. The `Verifier` checks the same rules the circuits
proved (subject match, city/district match, no double-vote) in the clear, then
emits a minimal-disclosure `VoteAttestation` (vote outcome + pseudonymous hash
only) for the agency to tally. Simpler than ZK-SNARKs — no trusted setup, no
circuits — but requires trusting the `Verifier` party, unlike a zk-SNARK.

## Build & test any variant

Requires the DAML SDK (`daml` on `PATH`) and a JVM (11+/17) for the script
runner.

```bash
cd daml-media-voting/<variant>/
daml build
daml test
```

See each variant's own `README.md` for its data-model mapping, design
decisions, and (for `canton-privacy/`) the full circuit-constraint ↔ DAML-check
table.

## Editor setup (VS Code)

`.daml` files need the Daml language extension for syntax highlighting and
IDE support — without it they render as plain grey text.

The extension isn't reliably installable by ID from the VS Code Marketplace
UI/CLI (`DigitalAssetHoldingsLLC.daml`) in some environments. The reliable
path is to let the Daml SDK install its own bundled copy:

```bash
daml studio --replace=published
```

This installs `digitalassetholdingsllc.daml-bundled` (falling back
automatically if the marketplace lookup fails) and opens VS Code. After it
runs, reload the window (`Ctrl+Shift+P` → "Reload Window") and reopen any
`.daml` file.
