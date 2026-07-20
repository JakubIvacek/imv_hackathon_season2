# Media Voting — NO-ZK baseline (DAML / Canton)

A DAML port of the media / news-event credibility voting platform, targeting
Canton. This is **variant 1 of 3**: the deliberately naive, **no-privacy**
baseline. Two privacy-preserving variants (a ZK-SNARK variant and a
Canton-native-privacy variant) are separate follow-up tasks and are **not** in
this project.

Source of truth for the data model:
`../../media-voting-smart-contract/src/MediaVoting.sol` (the no-ZK path only;
the ZK-SNARK `voteOnMediaWithProof` / `IZKVoteVerifier` path is intentionally
omitted here).

## ⚠️ No privacy — this is the point

This variant has **no privacy properties whatsoever**, on purpose, so it can be
the transparent contrast against the later privacy-preserving variants:

- Every individual vote is a full ledger contract (`EventVote` / `MediaVote`)
  whose content — the voter's `Party`, their `voterHash`, `support`, and
  `isLocalVoter` — is visible in cleartext to **all stakeholders** of that
  contract: the reporter (signatory) and the whole `community` observer list.
- `voterHash` is used **only** for de-duplication, exactly like the Solidity
  `mapping(bytes32 => bool) hasVoted`. It is not a privacy mechanism — there is
  no zero-knowledge proof of eligibility, no unlinkability, and no hiding of who
  voted or how.

Do not use this variant where voter privacy matters.

## Structure & mapping to the Solidity contract

Solidity keeps a growing `NewsEvent[]` array with nested `MediaItem[]` arrays
and per-item `mapping(bytes32 => bool)`. DAML has no mutable nested arrays and
contracts are immutable, so the model differs deliberately:

| Solidity | DAML (this project) | Notes |
|---|---|---|
| `struct NewsEvent` + `NewsEvent[]` | `template NewsEvent`, keyed on `(reporter, eventId)` | Each event is its own contract. `eventId` is the stable identity (Solidity's array index). |
| `struct MediaItem` nested in event | `template MediaItem`, keyed on `(reporter, eventId, mediaId)` | Separate template. Links to its event by the **natural key** `(reporter, eventId)`, **not** by ContractId — the event's ContractId changes every time its tally is updated. |
| `mapping(bytes32 => bool) hasVotedOnEvent` | `template EventVote` with contract **key** `(reporter, eventId, voterHash)` | A second `create` with a colliding key is rejected by the ledger — the idiomatic replacement for `require(!hasVoted[...])`. |
| `mapping(bytes32 => bool) hasVoted` (per media) | `template MediaVote` with key `(reporter, eventId, mediaId, voterHash)` | Same de-dup mechanism at media granularity. |
| `createEvent(...)` | `create NewsEvent` (a plain contract creation) | Modeled as direct creation; DAML has no need for a factory here. |
| `addMediaItem(...)` | `nonconsuming choice AddMediaItem` on `NewsEvent` | Nonconsuming — adding media doesn't disturb the event or its tallies. |
| `voteOnEvent(...)` | `consuming choice VoteOnEvent` on `NewsEvent` | Consuming because updating a tally = archive + recreate with incremented counters. |
| `voteOnMedia(...)` (no-ZK `_vote`) | `consuming choice VoteOnMedia` on `MediaItem` | Same increment logic as Solidity. |
| `hasVotedOnEvent` / `hasVotedOnMedia` (view) | contract-key lookups (`queryContractKey`) | See `hasVotedOnEvent` / `hasVotedOnMedia` helpers in `daml/Test.daml`. Not on-ledger choices — DAML views are ledger queries. |
| `getEvent` / `getMediaItem` (view) | `queryContractId` / `queryContractKey` | Plain ledger reads over the contract fields. |
| `voteOnMediaWithProof`, `IZKVoteVerifier`, ZK mode flags | *omitted* | Out of scope for the no-ZK baseline. |

### Preserved field names & semantics

`NewsEvent`: `reporter` (Solidity `address` → DAML `Party`), `name`,
`description`, `location`, `timestamp`, `reporterName`, `reporterOrg`, plus the
tallies `yesCount` / `noCount` / `localYesCount` / `localNoCount`.
`MediaItem`: `uri`, `description`, `mediaType`, and the same four tallies.

Vote increment logic matches Solidity exactly: `support` adds to `yesCount`
(else `noCount`); when `isLocalVoter` is `True` it additionally adds to
`localYesCount` / `localNoCount`.

### Intentional deviations from a literal 1:1 port

- **Separate `MediaItem` template instead of a nested array**, referenced by
  natural key — DAML has no mutable nested arrays, and referencing by ContractId
  would break every time the parent is recreated to update a tally.
- **Votes are their own contracts with contract keys** rather than a boolean
  mapping — this is how DAML expresses "reject a duplicate" at the ledger level.
  The **maintainer is the reporter**, so the key namespace is shared across all
  voter identities: two different DAML `Party`s presenting the same `voterHash`
  still collide (matching the intent of hashing a Verifiable Credential).
- **A `community : [Party]` observer list** was added to every template. Solidity
  voting is open to any `msg.sender`; DAML requires a controller to be a
  stakeholder, so eligible voters are modeled as observers. This also makes the
  "no privacy" property concrete: the whole community sees every vote.
- **`eventId` / `mediaId` are supplied by the caller** (as in Solidity, where
  they equal array indices) rather than auto-incremented, since DAML has no
  cheap global counter.

## Build & test

Requires the DAML SDK (`daml` on `PATH`) and a JVM (JRE 11+ / 17) for the
script runner.

```bash
# from this directory (daml-media-voting/no-zk/)
daml build      # compiles to .daml/dist/media-voting-no-zk-0.1.0.dar
daml test       # runs the Daml Script tests in daml/Test.daml
```

### Tests (`daml/Test.daml`)

- **`happyPath`** — creates an event, adds a media item, casts yes/no votes
  (local and non-local) on both the media item and the event, and asserts every
  tally (`yesCount` / `noCount` / `localYesCount` / `localNoCount`) matches the
  Solidity increment rules. Also exercises the `hasVotedOnMedia` /
  `hasVotedOnEvent` query helpers.
- **`doubleVoteRejected`** — casts a vote, then asserts (via `submitMustFail`)
  that a second vote with the **same `voterHash`** is rejected by the ledger on
  both the media and event paths, because it would collide with the existing
  vote's contract key.

Both scripts pass under SDK 2.10.4.
