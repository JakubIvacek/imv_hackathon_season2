# Deploy & call plan — all three variants

Not yet implemented — this is a plan to work from, covering
[`no-zk/`](./no-zk/), [`zk-snark/`](./zk-snark/), and [`canton-privacy/`](./canton-privacy/).

## Tier 1 — local single-node sandbox (do this first, for all three)

`daml start`, run from inside each variant's directory, builds the project,
starts a local Canton Sandbox ledger, uploads the DAR, and opens Daml
Navigator (a web UI, `http://localhost:7500`) where you log in as a party and
click through creating/exercising contracts.

Steps needed per variant:

1. Confirm `daml start` boots cleanly (build → sandbox → Navigator, no port
   conflicts if testing more than one variant — use one at a time, or assign
   distinct ports).
2. Add an `init-script` (a small Daml Script wired into `daml.yaml` via
   `init-script: Setup:init`) that allocates the parties each variant needs
   and creates one starter `NewsEvent` + `MediaItem`, so Navigator isn't a
   blank ledger on first load:
   - `no-zk/` — a `reporter` party + a couple of `community` voter parties.
   - `canton-privacy/` and `zk-snark/` — `issuer`, `voter`, `verifier`,
     `reporterAgency` parties.
3. Write a per-variant click-path (which party to log in as, which choice to
   exercise, in what order) — this is the part that needs to be spelled out
   explicitly, since Navigator requires logging out and back in as a
   different party to exercise a controller-restricted choice, which trips
   people up:
   - **no-zk**: log in as a `community` voter → find the starter
     `MediaItem` → exercise `VoteOnMedia` (support, isLocalVoter, a
     `voterHash` text) → try the same `voterHash` again and watch the ledger
     reject it.
   - **canton-privacy**: log in as `issuer`/`voter` → create the
     `VerifiableCredential` → log in as `verifier` → exercise
     `VerifyAndAttest` → log in as `reporter` → exercise `TallyEventVote` /
     `TallyMediaVote` on the resulting `VoteAttestation`.
   - **zk-snark**: log in as `voter` → create `ZKProofSubmission` → log in as
     `verifier` → exercise `AttestProof` with `proofVerified = True` (acting
     as the mocked off-ledger snarkjs check) → log in as `reporter` → tally
     the resulting `ZKVoteAttestation`.

## Tier 2 — programmatic calls

Once Tier 1 works, drive the same sandbox from code instead of clicking in
Navigator — needed if we want a demo frontend or to actually wire up the
`zk-snark/verifier-service/verify.md` sketch:

- `daml script --ledger-host ... --ledger-port ...` against the running
  sandbox, reusing/adapting the existing `Test.daml` scripts, or
- the `@daml/ledger` TypeScript bindings to submit create/exercise commands
  from a small script or app — same command shape the verifier-service
  sketch already assumes.

## Tier 3 — real multi-participant Canton topology

The sandbox is a single node, so `canton-privacy`'s privacy claim (VC never
reaches the reporter's node) is enforced but not visibly demonstrated — every
party lives on the same participant. To actually show it: run multiple
Canton participant nodes connected to a shared domain, host different
parties on different participants, upload the DAR to each. Bigger lift; only
worth it if judges care about seeing the cross-node isolation directly
rather than taking the contract-visibility model on faith.

## Open questions before building any of this

- Which variant(s) to prioritize for the demo — all three, or just the one
  we're pitching hardest (`canton-privacy`)?
- Tier 1 only, or invest in Tier 2/3 given hackathon time left?
