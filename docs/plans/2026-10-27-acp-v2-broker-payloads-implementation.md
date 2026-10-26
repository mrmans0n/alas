# ACP v2 raw broker payload implementation plan

> **For agentic workers:** Use superpowers:executing-plans with the established native workflow and one fresh final review.

**Goal:** Define a shared Swift/Rust byte-preserving broker payload contract, without installing a runtime transport path.

**Architecture:** A passive immutable byte value encodes as exactly two strings, `["alas.acp.raw-json.v1", "<canonical padded base64>"]`. Generic broker JSON carriers see only strings; semantic ACP decoding remains a separate future consumer step.

**Tech stack:** Swift Codable/Swift Testing, Rust serde/base64, shared JSON fixtures.

**Spec:** [Approved design](2026-10-26-acp-v2-broker-payloads-design.md).

## Global constraints

- Fixed baseline `4a3ac981960c4c90ce66898741d4a6aa5026ef36`, branch `nacho/acp-v2-broker-payloads`; keep changes local until shipping and preserve the pre-existing research note.
- No new runtime schemas, advertisements, helper capture, v2 eligibility, SSH deployment, ACK/lease/cursor/queue, or runner/persistence changes. Production stays v1.
- Exact two-element string pair, discriminator `alas.acp.raw-json.v1`, strict canonical padded RFC 4648 standard base64. Reject wrong shape, extra/missing elements, unknown formats and noncanonical encodings.
- Source JSON is opaque bytes, including malformed JSON, duplicate keys and invalid UTF-8. Do not normalize, parse, recursively interpret markers or add authority/consumption.
- Reuse existing libraries and dependencies; do not add a parser or move AlasCode into AlasPlatform.

## Review focus

- Distinguish wrapper validity from source-JSON validity, preserving diagnostic bytes.
- Reject nonzero base64 padding bits and ignored characters consistently on both platforms.
- Reject extra tuple values or unknown formats rather than accidentally upgrading.
- Compare against common literal source expectations, not merely self-round-trips.
- Keep production broker schemas and advertisements untouched; generic carrier tests do not prove journal/SSH installation.

## Task 1: Shared corpus and Swift contract

Files: create `Packages/AlasCore/Sources/AlasPlatform/SSH/ACPBrokerRawJSONPayload.swift`, `Packages/AlasCore/Tests/AlasCoreTests/ACPBrokerRawJSONPayloadTests.swift`, and shared `Packages/AlasCore/Tests/AlasCoreTests/Fixtures/acp-raw-json-payloads.json`.

Interfaces: public `ACPBrokerRawJSONPayload: Codable, Equatable, Sendable`, `init(bytes: Data)`, immutable `bytes: Data`. Tests load the corpus relative to #filePath. Corpus valid entries have a literal UTF-8 source or explicit byte list plus the expected string pair; invalid entries have named wrapper values.

- [x] Write parameterized `sharedFixturesPreserveExactSourceBytes` tests asserting independent expected bytes and encoded wire pair; `genericCarriersPreserveEvidenceAcrossHops` tests with event and cached-outcome-shaped carriers through ACPBrokerJSONValue twice; `malformedWrappersAreRejected` tests using the shared corpus.
- [x] Run `swift test --package-path Packages/AlasCore --filter ACPBrokerRawJSONPayloadTests` with isolated build/cache paths. Expected RED: missing public wrapper contract.
- [x] Implement an unkeyed Codable pair, strict discriminator/cardinality/types, and base64 decode/re-encode equality. Construction does not parse bytes.
- [x] Run the new suite and existing ACP protocol/delivery suites; inspect nonzero test/suite counts and failures.

## Task 2: Rust contract and final evidence

Files: extend `AlasHelper/src/acp_broker_protocol.rs` and `AlasHelper/tests/acp_broker_protocol.rs`; consume the same corpus with `include_str!` relative to the test source.

Interfaces: public `AcpRawJSONPayload`, `new(bytes: Vec<u8>) -> Self`, `bytes(&self) -> &[u8]`, private owned bytes, Eq/Clone/Debug plus custom serde for the fixed string pair. Reuse `base64::engine::general_purpose::STANDARD`.

- [x] Add `raw_payload_shared_fixtures_preserve_exact_source_bytes`, `raw_payload_generic_carriers_preserve_evidence_across_hops`, and `raw_payload_rejects_malformed_wrappers` to the existing protocol suite. Mirror independent fixture expectations and generic event/cache transit, without production-schema changes.
- [x] Run `cargo test --manifest-path AlasHelper/Cargo.toml --locked --test acp_broker_protocol raw_payload_`. Expected RED: missing Rust wrapper contract. Swift tests run first per repository policy.
- [x] Implement strict tuple serde and canonical base64 validation, with no semantic payload parsing or new dependency.
- [x] Run the focused Rust protocol target, then final affected Swift suites, scoped Rust formatting, full SwiftFormat lint and whitespace checks. Do not run app builds for these pure codecs.
- [x] Obtain one fresh final read-only review against the fixed base plus new-file manifest. Fix material findings with RED/GREEN evidence in one pass; do not rereview.
- [x] Record results and any scope decisions in the ledger and plan; update umbrella #2213 with contract-only evidence, keeping installation/live items unchecked. Leave commits/PR for shipping.

## Local result

Implemented on `nacho/acp-v2-broker-payloads`; shipping requested on 2026-10-27.

- Swift: 14 tests in 3 suites passed, including the new raw payload suite and existing negotiation/delivery suites. The corpus exercises 6 valid cases and 19 invalid wrapper cases.
- Rust: all 26 tests in the existing broker protocol target passed with locked offline dependencies. Both language suites use the same source and wire fixtures and exercise generic event/cache-shaped carriers twice.
- Full SwiftFormat lint: 0/2651 files require formatting. New Rust sections match rustfmt output; scoped tracked/new-file whitespace checks pass. Existing unrelated Rust formatting is unchanged.
- One fresh final review found no code defects; its Minor checklist note was handled by this planned completion update. No deferred minor findings or second review.
- Production remains on ACP1. No capability advertisement, capture/IPC/journal installation, broker/SSH/runtime interoperability, app-build or CI result is claimed. The wrapper is an unused transport contract, not a semantic ACP decoder.

Execution decision: retained the established native workflow and docs/plans location, without another plan-method approval menu. If the decomposition were unsuitable it would need adjusting, but the approved contract scope is unchanged. Work stays local until shipping; preserve the pre-existing research note.
