# Raw broker transport implementation plan

> **For agentic workers:** Use superpowers:executing-plans, native inline execution and one fresh final review.

**Goal:** Install opt-in raw-v2 capture, generation-fenced broker RPC/state and provenance-aware Swift delivery while retaining production legacy-v1.

**Architecture:** Shared immutable wire context and explicit raw fields/cases; Rust captures full bytes before parsing routing headers. ACPBrokerClient retains its legacy path and delegates only raw mode to an actor-isolated transport state helper. This helper owns transport cursors, not a second ACP session model.

**Tech stack:** Swift Codable/Testing/actors, Rust serde RawValue/base64, existing broker/helper RPC and fixture tests.

**Spec:** [Approved design](2026-10-27-acp-raw-broker-transport-design.md).

## Global constraints

- Fixed base `1176148430eff1402b2e8a5c9b456532e962c2ce`; branch `nacho/acp-raw-broker-transport`. Keep local until shipping; preserve unrelated research note.
- Only legacy-v1 and raw-v2 contexts; raw methods use `acp/raw/*`, capability `acpRawFrames: 1`. Missing context means legacy only. Fail unknown/mismatched context or unavailable expected generation before mutation/replacement.
- Raw capture precedes String/Value parsing. Preserve original frame before LF, final EOF frame, invalid UTF-8, opaque numbers and diagnostic evidence.
- All raw frames require explicit single-use consumption; preserve source generation/cursor/provenance. No live ACP2 eligibility, runner/UI/tools/SSH deployment, outbound arbitrary JSON overhaul or helper release.
- No task commits; native execution ledger in /private/tmp. One fresh final review, one material fix pass, no rereview.

## Review focus

- Context rejection precedes legacy restart and late-open cleanup, including dead raw generations.
- Header parsing distinguishes absent/null and duplicate routing fields without numeric conversion of opaque data.
- Completion/echo/replay/pending snapshots share cursor authority without auto-ACK or stale-generation mutation.
- Raw error projections match retained source bytes and retain hook rejection semantics.
- Raw acceptance never derives v1 foreground completion; serialized replay budgets include wrapper expansion.

## Task 1: Shared schemas and exact raw response/delivery contracts

Files: Swift platform ACPBrokerProtocol/RemoteHelperProtocol and new ACPBrokerWireContext; AlasACP raw delivery/response helpers and ACPV2SessionUpdateDelivery; Rust acp_broker_protocol/acp_broker models; package protocol tests and Rust existing protocol tests.

Interfaces: ACPBrokerWireContext legacyV1/rawV2 encodes acpVersion/payloadFormat; optional wireContext on metadata/control params, expectedGeneration on open. Raw frame alternatives on events, outcomes, pending requests and init/session caches; real origin/completed cursor fields. Swift exact response decoder retains public raw RPC errors and validates small projections.

- [x] Write package context/schema/raw response/provenance contract tests; run expected missing-contract RED.
- [x] Implement Swift contracts and run affected package suites GREEN.
- [x] Add Rust schema/raw state regressions and run missing-contract RED; implement matching models/state, run protocol target GREEN.

## Task 2: Rust byte capture and helper generation fencing

Files: AlasHelper Cargo.toml, acp_broker_process.rs, main.rs; extend existing process/protocol/crash-recovery tests and deterministic fixture adapter.

Interfaces: raw_value feature, strict routing header; raw fields remain base64 wrappers across existing IPC. Distinct raw namespace and context checked before side effects; raw open preserves expected generation, refuses automatic replacement; capability advertised only by supporting helper. Legacy list excludes raw generations.

- [x] Add behavior regressions for source frames/caches/pending requests, null/error/duplicate IDs, invalid UTF-8/EOF, matching reattachment and mismatched/dead generation; run RED.
- [x] Implement raw routing/capture/cache handling, mode-fenced control/IPC and unknown raw activity state; keep v1 branches unchanged.
- [x] Run focused Rust protocol/process and real helper fixture cases, inspecting actual counts and process cleanup; verify replay byte budgets and hook rejection retention.

## Task 3: Swift service namespace/capability and raw-mode client

Files: RemoteHelperClient, LocalACPBrokerService, ACPBrokerClient; new ACPRawBrokerTransport actor/helper. Extend existing app broker/helper suites; package pure transport tests where they belong.

Interfaces: service calls select namespace from required wireContext; current helper generation capability check. Raw actor exposes v2 updates, other raw frames, generation/durable summary and exact send/error/cache responses. Existing ACPBrokerClient remains the public facade, default legacyV1. Raw provenance is additive on v2 deliveries.

- [x] Add RED tests for unsupported helpers and mismatch-before-cleanup; raw cache/stream delivery, ordered explicit ACK, deduped pending snapshot, stale callbacks, shutdown and acceptance-not-completion.
- [x] Implement service fencing and raw delegation; validate all snapshots before applying state. Finish inactive streams; expose genuine journal/snapshot origin and one shared authority. No production factory changes.
- [x] Run affected package tests first, then attempt focused app broker/helper suites. Package checks passed; app-target result is tracked separately in the evidence ledger.

## Task 4: Final evidence and tracking

- [x] Run final affected package/Rust/app checks, full SwiftFormat, scoped Rust formatting and whitespace checks. Inspect actual selected tests; do not claim live/CI/SSH results from fixtures.
- [x] Obtain fresh final read-only review against fixed base and complete untracked manifest. Fix material findings with RED/GREEN in one pass; ledger scope rulings/minors.
- [x] Complete plan/ledger and update umbrella #2213 with exact local evidence and remaining runner/live gaps. Leave uncommitted until shipping.

## Local evidence

- Package: 68 tests in 8 affected suites passed after the review fix pass, including existing Codex hooks. No full app test plan was run.
- Rust: 28 protocol tests, 34 broker process unit tests, one real raw helper/supervisor integration and one existing legacy broker compatibility integration passed. Local Unix socket tests required sandbox access.
- Full SwiftFormat: 0/2656 files require formatting, 1 skipped. Whitespace checks passed; Rust formatting applied to the changed sections.
- One fresh final review found two Important issues and a missing initial durable-state export. The export was regraded as Important because recovery needs the validated context before any consumption. All were fixed with failing-then-passing regressions. An additional same-key trace pins old rejection callbacks against a newer completion. No second review and no deferred minor findings.
- App: the final reviewed-source run passed ACPBrokerClientTests and RemoteHelperClientTests, 95 definitions / 100 executions, no failures or skips. Verified with xcresulttool, not exit status alone. Umbrella #2213 was updated with local completion and the remaining integration gaps.
- Production stays legacy-v1. This evidence does not establish live adapter compatibility, SSH transport/deployment, runner/UI integration or crash durability beyond the surviving supervisor. Changes remain local until shipping is requested.
