# ACP v2 lossless stdio ingress implementation plan

> **For agentic workers:** Use superpowers:executing-plans with the established native inline workflow and one fresh final review.

**Goal:** Deliver exact stdio v2 notifications with explicit single-use consumption, preserve successful response values, and retain production v1 selection.

**Architecture:** Add a raw-frame delivery value using the existing JSON codec, then an immutable exclusive stdio stream mode. Keep broker/SSH and runner installation separate, and reject a connection/decoder-mode mismatch before initialize handoff.

**Tech stack:** Swift, Swift Testing, AlasACP core and existing app transport test suites.

**Spec:** [Approved design](2026-10-26-acp-v2-stdio-ingress-design.md).

## Global constraints

- Fixed base `62e1b51678284c94d4bf116ecc2138f9ebdc056a`; no mid-validation rebase.
- Production stays v1; no adapter eligibility, settings, broker/helper, SSH offset, runner, storage, queue, permission, or execution changes.
- Reuse LSPJSONValue raw parser/writer. Exact numeric tokens survive; generic error responses and outgoing serialization stay outside scope.
- One immutable protocol mode and one active update stream per stdio client. Preserve default-v1 normalization, fan-out, watermark and acknowledgement behavior.
- Yield/decode/application/shutdown never consume a v2 delivery automatically; copied handles acknowledge at most once outside locks.
- Keep work and `/private/tmp` execution artifacts local until shipping; preserve the existing research note.

## Review focus

- An identifiable v2 session/update with malformed or huge id still reaches explicit decode failure, without generic-head routing silently dropping it.
- Shutdown racing with delivery cannot publish a new v2 frame or automatically consume its callback; buffered deliveries retain original authority.
- A callback may reenter the same shared handle while another task acknowledges a copy, without deadlock or duplicate execution.
- Unknown fields with unrepresentable numeric data survive successful response extraction and frame-to-owner application.
- Fixture-only v2 mode cannot bypass production initialize selection; mismatches cause no request handoff or active-decoder reinterpretation.

## Task 1: Raw delivery codec and consumption

Files: create `Packages/AlasCore/Sources/AlasACP/ACP/Protocol/ACPV2SessionUpdateDelivery.swift` and one coherent `Packages/AlasCore/Tests/AlasCoreTests/ACPV2SessionUpdateDeliveryTests.swift` suite.

Interfaces: `ACPV2SessionUpdateDelivery(frame:connectionID:durableConsumptionAcknowledgement:)` exposes original Data and UUID, pure `decode() throws -> ACPV2SessionUpdateEnvelope`, and `acknowledgeDurableConsumption()`. Copies share a private synchronized single-use handle.

- [x] Write valid raw frame/owner, unknown/malformed notification, copied-concurrent/reentrant acknowledgement, and absent-callback tests. Assert bytes and numeric tokens independently of retained raw state, and zero callback activity before explicit consumption.
- [x] Run the delivery suite with isolated SwiftPM paths. Expected RED: missing delivery contract.
- [x] Implement exact notification validation and a single-use callback extracted under lock and invoked after unlocking. Keep schema/decode failure raw and unconsumed.
- [x] Run delivery/session-owner/lifecycle/message/activity/negotiation suites. Expected GREEN with actual counts.

## Task 2: Exclusive stdio delivery and exact results

Files: modify `ACPClient.swift` and `ACPStdioClient.swift` in the same protocol directory; extend `AlasTests/ACP/Protocol/ACPStdioClientTests.swift` using its existing fake transport/fixture helpers.

Interfaces: ACPClient adds `sessionUpdateProtocolVersion` and `incomingV2Updates`, both compatible v1/finished defaults. Stdio constructors accept immutable `sessionUpdateProtocolVersion: ACPProtocolVersion = .v1`, expose stable `updateConnectionID`, and finish the inactive stream. The v2 path emits one full-frame delivery per session/update before generic head decoding; count/yield and termination are synchronized.

- [x] Add frame-to-owner tests with ordered valid/unknown/malformed deliveries and mode/watermark exclusivity; add shutdown/exit/late-frame and replacement-context traces. Add successful result variants covering exact opaque numbers, scalar/array/object/null and absent result, preserving response callback/request matching.
- [x] Run focused app stdio suite. Expected RED: missing mode/stream APIs or legacy numeric conversion. If infrastructure prevents a red test execution, confirm absent contracts through compiler diagnostics and retain all app checks for final verification.
- [x] Implement immutable modes and raw v2 routing, finish behavior, termination guard and shared callback ownership. Replace JSONSerialization result extraction with the existing exact parser/writer while preserving error precedence and pending-response settlement. Leave v1 extensions/fan-out compatible.
- [x] Run focused stdio suite plus affected package suites. Expected GREEN with actual selected suite/test counts; record infrastructure limits if app execution is unavailable.

## Task 3: Negotiation guard and final evidence

Files: modify `Packages/AlasCore/Sources/AlasACP/ACP/Protocol/ACPConnection.swift`; extend `AlasTests/ACP/Protocol/ACPConnectionTests.swift`.

Interfaces: initialize rejects a configured update mode that differs from requested or validated selected protocol before session work; the current v1-only policy rejects a v2 client before sending initialize. No active-client mode setter is introduced.

- [x] Add a mismatched-mode test asserting initialize fails before any request handoff and does not capture a negotiated version. Existing v1 initialization remains covered.
- [x] Run the focused connection test. Expected RED: initialize sends through an incompatible client mode.
- [x] Implement the guard without changing selection, bootstrap schemas, cached initialize handling, or advertised capabilities.
- [x] Run affected package suites first, then focused stdio and connection app suites with isolated DerivedData and required macro/plugin flags. Inspect counts, full SwiftFormat lint, and whitespace checks on tracked/new scoped files.
- [x] Obtain one fresh final code review of the fixed baseline plus complete new-file manifest. Fix material findings in one RED/GREEN pass; no second review.
- [x] Update plan, ledger, and umbrella #2213 with local evidence and deferred broker/SSH/live integration. Keep changes uncommitted until shipping.

## Local execution result

Implemented on `nacho/acp-v2-stdio-ingress`; shipping requested on 2026-10-26. Validation used the fixed baseline above.

- Delivery, session owner, lifecycle, message, activity, and negotiation package suites passed, 70 tests in 6 suites.
- Existing stdio and connection app test sources were temporarily compiled with only `import Alas` replaced by `import AlasCore`. Combined validation passed, 127 tests in 8 suites, including 57 transport/connection tests. Temporary copies were removed.
- The incompatible-mode guard had behavioral RED evidence: initialize sent a request, returned normally, and captured v1. It now rejects before handoff.
- One fresh final review found an Important exact-parser-failure fallthrough into v1 routing. Duplicate-key and excessive-depth/huge-ID regressions first failed with count0, callback1, and no raw delivery, then passed after method-only identification and an explicit v1 fence. No second review was run; no minor findings were deferred.
- Full SwiftFormat lint and scoped whitespace checks passed. App Xcode attempts remain inconclusive: after cache access was restored, builds repeatedly reported unrelated successful compiler commands producing no output. The bounded-parallelism retry was stopped after reproducing those errors; no app-target, CI, or live-adapter pass is claimed.
- Production selection stays v1. Broker/SSH losslessness, cursor ordering, runner/persistence/replay, and live adapter integration remain separate work. Generic JSON-RPC error data and outgoing serialization retain existing behavior.

Execution decisions: keep docs and the ledger local until shipping; use an explicit compiler probe for the missing client contract after unavailable Xcode RED evidence; use the temporary SwiftPM harness to validate the unchanged app test bodies; use a method-only fallback solely to retain rejected raw frames. The costs are local-only artifacts until shipment, outstanding app-target evidence, and a future diagnostic-routing case if the parsers disagree on another recognizable shape. The exact decoder remains authoritative.
