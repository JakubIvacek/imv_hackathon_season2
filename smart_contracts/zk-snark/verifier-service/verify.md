# Off-ledger verifier service — design sketch (UNIMPLEMENTED)

> **Status: not implemented, and not runnable in this environment.** Two things
> are missing here that a real deployment needs:
>
> 1. **No live Canton ledger** to connect to (no JSON API / gRPC endpoint, no
>    allocated `Verifier` party token).
> 2. **No compiled proving/verification keys.** The Circom circuits at
>    `../../../ZK-SNARKs/identity-verifier/IdentityCircuit.circom` and
>    `../../../ZK-SNARKs/location-verifier/LocationCircuit.circom` have not been
>    compiled+trusted-setup in this environment, so there is no `*.vkey.json` to
>    verify against and no witness generator to produce real proofs.
>
> Because of that, proof validity is **mocked** in the DAML Script tests (see
> `daml/Test.daml` and the `AttestProof` choice in `daml/MediaVoting.daml`),
> exactly the way `MockZKVoteVerifier.sol` mocks it in the Solidity project. This
> file is the concrete blueprint of the real service that mock stands in for —
> written so it could be implemented directly, not run as-is.

## What this service is

The one trusted component of the ZK-SNARK variant. It is the DAML/Canton
analogue of the on-chain `IZKVoteVerifier` in Solidity — except the pairing
check happens **off-ledger** (Canton has no EC-pairing precompile), and its
boolean result is written back on-ledger as a `ZKVoteAttestation`.

Loop, run as the single `Verifier` party:

1. **Watch** the ledger for new `ZKProofSubmission` contracts (the `Verifier` is
   an observer, so its participant node receives them).
2. **Verify** each submission's Groth16 proof off-ledger with
   `snarkjs.groth16.verify(vkey, publicSignals, proof)`.
3. **Attest**: if (and only if) verification returns `true`, submit a ledger
   command exercising `AttestProof` on that submission **as the `Verifier`
   party**, which creates the `ZKVoteAttestation` + `ZKNullifier`. If it returns
   `false`, do nothing (or record it out-of-band); never exercise `AttestProof`
   with `proofVerified = true` for a proof that did not verify.

## Trust boundary (say this to judges)

A real on-chain Groth16 verifier needs **no** trusted party at verification time
— the chain checks the math. This service **is** trusted: it must run snarkjs
honestly and report the boolean truthfully. Hardening step (considered, not
built): replace the single verifier with an **N-of-M federated quorum** whose
attestations must agree — reduces trust in any one node at the cost of much more
party/authorization plumbing.

## Sketch (TypeScript, `@daml/ledger` JSON API + `snarkjs`)

```ts
// verify.ts — UNIMPLEMENTED SKETCH. Real vkey/keys + a live ledger required.
import Ledger from "@daml/ledger";
import * as snarkjs from "snarkjs";
import fs from "node:fs";
// Codegen output from `daml codegen js` over media-voting-zk-snark-0.1.0.dar:
import { MediaVoting } from "./generated";

// --- config -------------------------------------------------------------
const LEDGER_HOST   = process.env.LEDGER_HOST   ?? "http://localhost:7575";
const VERIFIER_JWT  = process.env.VERIFIER_JWT!;    // token for the Verifier party
const VERIFIER_PARTY = process.env.VERIFIER_PARTY!; // Party id of the Verifier

// One verification key per circuit (from `snarkjs zkey export verificationkey`).
// Choose by whether the submission is an event-level or media-level / locality
// proof; both circuits share pk_auth/address/H_VC public signals.
const locationVkey = JSON.parse(fs.readFileSync("keys/location.vkey.json", "utf8"));

const ledger = new Ledger({ token: VERIFIER_JWT, httpBaseUrl: LEDGER_HOST });

// --- map the on-ledger PublicSignals record to snarkjs's ordered array ---
// snarkjs expects publicSignals as an ordered string[] matching the circuit's
// `main{ public [...] }` declaration. LocationCircuit order:
//   [ pk_auth[0], pk_auth[1], address, vote, req_city, req_district, H_VC ]
// The on-ledger `PublicSignals` stores these as field-encoded Text; a real impl
// must decode them back to the exact field-element strings the circuit used.
function toSnarkjsPublicSignals(ps: MediaVoting.PublicSignals): string[] {
  return [
    /* pk_auth split */ ...decodePkAuth(ps.pkAuth),
    /* address      */ decodeField(ps.subject),
    /* vote         */ ps.vote ? "1" : "0",
    /* req_city     */ decodeField(ps.reqCity),
    /* req_district */ decodeField(ps.reqDistrict),
    /* H_VC         */ decodeField(ps.hVC),
  ];
}

// --- main loop ----------------------------------------------------------
async function run() {
  // `streamQuery` pushes the active-contract set + live updates.
  ledger.streamQuery(MediaVoting.ZKProofSubmission).on("change", async (_state, events) => {
    for (const ev of events) {
      if (!("created" in ev)) continue;
      const cid = ev.created.contractId;
      const sub = ev.created.payload;

      // The proof itself: in production `proofBytes` is (or points at) the
      // Groth16 proof JSON produced by `snarkjs groth16 prove`.
      const proof = JSON.parse(sub.proofBytes);
      const publicSignals = toSnarkjsPublicSignals(sub.publicSignals);

      // *** THE OFF-LEDGER PAIRING CHECK — what DAML cannot do itself. ***
      const ok: boolean = await snarkjs.groth16.verify(
        locationVkey, publicSignals, proof,
      );

      if (!ok) {
        // Bad proof: never attest. (Optionally log / alert out-of-band.)
        continue;
      }

      // isLocalVoter: with the current LocationCircuit, cityEq/districtEq are
      // hard constraints, so a verifying proof already implies locality. If the
      // circuit is later split so locality is a public output, read it from
      // `publicSignals` instead of hardcoding true.
      const isLocalVoter = true;

      // Attest on-ledger AS the Verifier party. This creates the
      // ZKVoteAttestation + ZKNullifier (the choice enforces the nullifier
      // de-dup and rejects proofVerified === false).
      await ledger.exercise(MediaVoting.ZKProofSubmission.AttestProof, cid, {
        proofVerified: true,   // == snarkjs result `ok`
        isLocalVoter,
      });
    }
  });
}

run().catch(console.error);
```

## gRPC Ledger API alternative

Instead of the JSON API, the same loop can run on the gRPC Ledger API:

- **Read**: `TransactionService.GetTransactions` (or `StateService`
  `GetActiveContracts`) filtered to `ZKProofSubmission` for the Verifier party.
- **Write**: `CommandService.SubmitAndWait` with a single `ExerciseCommand`
  (templateId = `ZKProofSubmission`, choice = `AttestProof`, choiceArgument =
  `{ proofVerified: true, isLocalVoter: ... }`), `actAs = [VerifierParty]`.

## To make this real

1. `cd` into each circuit, `circom … --r1cs --wasm`, run the Groth16 trusted
   setup (`snarkjs groth16 setup` + a phase-2 contribution), and
   `snarkjs zkey export verificationkey` to produce `*.vkey.json`.
2. Stand up a Canton sandbox / participant, allocate `Verifier`/`Voter`/
   reporter parties, and mint a JWT for the Verifier.
3. `daml codegen js` over `media-voting-zk-snark-0.1.0.dar` for the typed
   `MediaVoting.*` bindings used above.
4. Implement `decodePkAuth` / `decodeField` to round-trip the field-element
   encoding chosen when the proof's public signals were written into
   `PublicSignals`.
```
