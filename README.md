# inMediaVeritas

A decentralized news verification application (DApp) that combats misinformation through cryptographic provenance, privacy-preserving community voting, and on-chain consensus — without any central arbiter of truth.

> For the full theoretical background, cryptographic design, and formal evaluation, see the accompanying paper *inMediaVeritas* (2026) by Jakub Ivácek, Patrik Baran, Tomáš Tisovský, Vojtech Babinský, Tomáš Miština, Matúš Hrkeľ, Richard Gazdík, Ivan Homoliak — STU FIIT, Bratislava, Slovakia.

## What it does

inMediaVeritas builds a trustless pipeline from raw media capture to verified content: reporters attach a location and publish media on-chain with a verifiable content hash, so any tampering is immediately detectable. Geographically eligible community members then vote on the credibility of each reported item, proving their eligibility without revealing who they are or exactly where they live. Credibility emerges from this on-chain consensus rather than from any editorial board or platform operator.

This repository is the **Canton / DAML hackathon port** of the project. The original implementation targets Ethereum; here we're reworking the core voting logic natively for Canton, exploring a few different approaches to the identity/locality privacy problem along the way.

## In this repo

- [`smart_contracts/`](./smart_contracts/) — DAML ledger models of the media-voting logic, built as three side-by-side variants exploring different privacy tradeoffs. See its [README](./smart_contracts/README.md) for details on each.
