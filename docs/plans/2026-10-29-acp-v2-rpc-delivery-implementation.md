# ACP 2 raw RPC delivery implementation plan

> **For agentic workers:** Use superpowers:executing-plans with the approved native inline method. TDD per task; one fresh final review and one material fix pass. No commits until shipping is requested.

**Goal:** Retain exact v2 RPC response evidence and explicit single-use consumption across stdio and raw broker clients.

**Architecture:** A shared AlasACP delivery owns source bytes, request binding and consumption. Successful ACPResponse and raw errors expose the same handle. Stdio performs strict v2 routing before its v1 decoder/defer; broker attaches the real operation cursor or explicit cache origin.

**Tech stack:** Swift 6, Swift Testing, existing exact JSON parser and transport fixtures.

**Spec:** [Approved design](2026-10-29-acp-v2-rpc-delivery-design.md).

## Global constraints

- Branch nacho/acp-v2-rpc-delivery, base 4af1882648c9f518b0391704390858962c88d55b. Preserve untracked adapter research and the pre-existing Ghostty checkout mismatch.
- Production remains v1-only; do not change outgoing serialization, queue/runner semantics, helper hook-retention policy, SQLite or pending adapter-request durability.
- Only method-absent exact frames can bind outgoing responses. Method plus result/error, invalid method, ambiguous parser failure and unmatched IDs stay unbound diagnostics. A valid inbound string method with neither result/error keeps its independent request namespace.
- Original full bytes are authority. All raw/legacy response/error acknowledgement views share one token. No parsing, dispatch error, shutdown or diagnostic yield auto-consumes.
- Keep stdio signed Int/string and broker UInt64 request domains distinct. Do not invent broker cache event provenance or source frames for synthetic transport errors.
- Focused package tests first, then affected native stdio/connection/broker suites. Confirm test counts. Keep work uncommitted.

## Files and shared interfaces

- Create `Packages/AlasCore/Sources/AlasACP/ACP/Protocol/ACPRawRPCDelivery.swift`: immutable delivery, strict pure decoding, raw error wrapper and shared consumption.
- Modify `ACPClient.swift` in that directory: optional `ACPResponse.rawDelivery`, overload `init(body: Data, rawDelivery: ACPRawRPCDelivery)` whose compatibility closure shares the raw handle. Existing initializer remains unchanged.
- Modify adjacent `ACPStdioClient.swift`: v2 diagnostic channel, strict outgoing-response routing, pending method metadata and lifetime-fenced callbacks. Preserve v1 path.
- Modify adjacent `ACPCodexHooks.swift`: classify the new stdio raw error without consuming it.
- Modify `ACP/Broker/ACPBrokerRawResponse.swift`: additive delivery view/initializer on existing ACPBrokerRawRPCError.
- Modify `ACP/Broker/ACPRawBrokerTransport.swift`: attach delivery to operation/cache results and errors using existing proven cursor selection.
- New package suite `ACPRawRPCDeliveryTests.swift` for the new value/parser. Extend existing `AlasTests/ACP/Protocol/ACPStdioClientTests.swift`, its `FakeJSONRPCTransport.swift` if synchronization is needed, and package `ACPBrokerRawClientTests.swift` for integration.

Shared type contract:
- `ACPRawRPCDelivery.Source`: `.stdio(requestID: JSONRPCID, method: String)`, `.brokerOperation(operationKey: ACPBrokerOperationKey, requestID: ACPBrokerAdapterRequestID, method: String)`, `.brokerSnapshotCache`, `.diagnostic`.
- Delivery immutable `receiptID: UUID`, `frame: Data`, `connectionID: UUID`, `source`, optional `brokerProvenance`. Constructor accepts optional callback. Copies and response/error compatibility closures share its token.
- `decode() throws -> Decoded`: exact raw ID (`LSPJSONValue`), optional result Data, optional projected JSONRPCError and optional full raw error LSPJSONValue. Validate supported IDs and exact expected binding. Error projection includes code/message and factual kind discriminator, while raw data stays exact in frame/rawError.
- `ACPRawRPCError`: `delivery`, optional `rpcError`, LocalizedError, explicit `acknowledgeDurableConsumption()`. `ACPBrokerRawRPCError.rawDelivery` is additive; keep old frame/rpcError/initializer compatibility and add a delivery initializer.
- Stdio concrete `incomingRawRPCDiagnostics: AsyncStream<ACPRawRPCDelivery>`; v1 stream finishes immediately. No ACPClient default/protocol requirement or diagnostic persistence owner in this slice.

## Review focus

1. Reversed request responses and overlapping inbound/outbound ID namespaces cannot settle the wrong call. Task2 covers exact binding and method-plus-response collisions.
2. Error data with 1e999 must stay an error with raw evidence, without Foundation fallback or early ACK. Tasks1/2.
3. Compatibility closure, copied raw value and error accessors cannot each consume one event. Tasks1/3 exercise shared token and reentry.
4. Cached responses and synthetic broker exits cannot manufacture live event authority. Task3.
5. An old same-key completion callback must not release the newer operation cursor; shutdown/late stdio evidence cannot gain replacement lifetime authority. Tasks2/3.

## Task 1: Raw value, strict parser and compatible consumption

Produces the shared delivery/Decoded/error/ACPResponse APIs above; Task2/3 consume them.

- [x] Add failing package tests for exact scalar/null/opaque success and raw errors; signed/string/UInt64 binding, contradictory envelopes and invalid IDs/method presence; shared response/error consumption under copies/concurrency/reentry.
- [x] Run selected tests and confirm missing-contract RED.
- [x] Implement the value/parser/token and optional response/error view. Keep pure decode separate from explicit consume, Int error bounds, and raw error projection factual.
- [x] Run new suite plus broker response, delivery and hook suites; inspect actual counts. No commit.

## Task 2: Stdio v2 response ownership and diagnostics

Consumes Task1 APIs; produces strict routing and diagnostic stream, pending method binding and same-lifetime callback guards.

- [x] Extend existing stdio suite with missing raw-view/early-error-consumption RED: matched success/null/error, exact error data, reversed prefixed-ID responses, malformed bound response, wrong/null IDs, duplicate/parser-rejected bytes and method/result ID collision. A valid inbound request using the same ID must not settle the outgoing request.
- [x] Synchronize only the shared transport fixture state that new concurrent tests access; no sleeps. Existing app suite may be compiled source-identically through a temporary SwiftPM import-adjusted harness for rapid cycles; remove before final native checks.
- [x] Implement v2 routing before legacy auto-consumption, using exact parser IDs and preserving ambiguity as diagnostics. Keep pending continuation removal atomic and exactly once, attach request method, and finish diagnostic stream on exit/shutdown without consuming buffered evidence.
- [x] Confirm raw errors classify hook code/kind without consumption. Check shutdown/late handles and existing v1 notification/request/result behavior. Run affected package and temporary harness suites, read counts. No commit.

## Task 3: Broker source/provenance and shared raw views

Consumes Task1 delivery/response/error contract; preserves current broker routing and ACK protection.

- [x] Extend existing broker suite with missing success/source/cache view RED and shared consumption, preserving the existing same-key replay race, hook error and detach regressions.
- [x] Attach exact frame/connection/operation/request/cursor to results and errors. Snapshot cache gets explicit cache source and no callback/cursor/key. Keep source-less -32074 diagnostic as existing ACPClientError.
- [x] Add common raw view to existing broker error while preserving frame/rpcError API and classification. No helper, operation replay or ACK ordering changes.
- [x] Run affected package broker/raw/hook/update-owner suites. No commit.

## Task 4: Verification, fresh review and tracking

- [x] Remove temporary harness sources; full SwiftFormat and tracked/new-file whitespace checks.
- [x] One fresh read-only whole-change review against fixed base including untracked source/tests/docs, excluding unrelated research and Ghostty mismatch. Fix material findings with RED/GREEN in one pass, no rereview; ledger deferred minors.
- [x] Run final package selection, then focused native ACPStdioClientTests, ACPConnectionTests and ACPBrokerClientTests against final stable sources. Confirm selected tests and xcresult counts. Do not edit sources during native compilation.
- [x] Update umbrella #2213 as locally implemented with evidence and exclusions. Complete plan/ledger. Leave uncommitted until separate shipping request.

## Preflight and rulings

Task1 source and consumption contracts feed both clients; Task2 stdio ID remains JSONRPCID while Task3 broker ID remains ACPBrokerAdapterRequestID. No narrowing or shared-interface mismatch. Diagnostics have no request binding. Cache frame IDs remain original and are exposed only through decoding, not invented current request bindings.

Keep the approved inline flow without another plan/execution menu. Repository focused checks override generic whole-suite defaults. The design's full validation/ownership requirements remain binding if an interface detail needs adjustment.

## Final evidence and handoff

Implementation and local review completed on 2026-10-30. Final package verification passed 80 tests in 8 suites. The preceding combined run passed 104 tests in 9 suites, including the existing app stdio suite compiled source-identically through SwiftPM with only its import changed. Temporary harness files were removed. Full SwiftFormat reported 0/2695 files requiring formatting, 1 skipped; tracked and new-file whitespace checks passed.

One fresh whole-change review found no Critical or Important issue. One Minor is deferred: two new stdio tests await file/diagnostic delivery without a deadline or guaranteed cleanup, so a future routing regression could hang those cases instead of producing a bounded failure. No production fix pass or second review was run.

Native ACPStdioClientTests, ACPConnectionTests and ACPBrokerClientTests validation remains inconclusive. The first attempt stopped on sandbox-denied SwiftPM cache writes. The next found a stale Lottie artifact path, repaired only in the isolated cache. A subsequent build selected Zig 0.17 for the preserved Ghostty checkout that requires 0.15.2. Using the installed matching Zig 0.15.2 then failed in Ghostty's libcxx sub-compilation on an undeclared INFINITY identifier. Tests were cancelled before execution; the completed result summary reports unknown with totalTestCount 0. No native, CI, live adapter or SSH pass is claimed. Source and dependency pins were not changed to work around these unrelated build failures.

Source code remained stable after review. Production still supports v1 only. No commit, push or PR was made. Leave this branch and its ledger for review/shipping; preserve unrelated adapter research and Ghostty checkout state. Submission-ledger and production-runner integration remain later work.
