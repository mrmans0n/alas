# ACP 2 inbound delivery implementation plan

> **For agentic workers:** Use superpowers:executing-plans with the established native inline workflow, meaningful TDD and one fresh final review. Keep changes uncommitted until shipping requested.

**Goal:** Preserve exact selected-v2 inbound method evidence and explicit consumption before legacy dispatch can normalize, answer or consume it.

**Architecture:** One immutable common delivery in AlasACP, a concrete stdio raw stream, and a stored common view on the existing broker facade. Existing update/RPC routing and v1 handlers remain separate. No persistence or response authority is added.

**Tech stack:** Swift, Swift Testing, LSPJSONValue, existing transport fixtures.

**Spec:** [Approved design](2026-10-31-acp-v2-inbound-delivery-design.md).

## Global constraints

- Fixed base79a8f405c910c0cf18b49db1105fb2321f3485ba, branch nacho/acp-v2-inbound-delivery. Preserve unrelated Ghostty/research.
- Production remains v1-only. No request ledger/recovery, response sending, permission decisions, files/terminal execution, UI, SSH or helper changes.
- Original frame Data is authority. Header decode and receipt consumption are independent; copies share one take-before-call token and preserve receipt UUID.
- Broker source keeps actual provenance and optional opaque pendingRequestID; never infer helper pending authority from a method/ID alone.
- V2 session/update stays exclusive. Mixed method/result/error, unsupported IDs and parser failures remain unbound RPC diagnostics without guessed IDs. Valid v2 methods bypass every legacy typed handler and automatic response.

## Files and interfaces

Create `Packages/AlasCore/Sources/AlasACP/ACP/Protocol/ACPV2InboundDelivery.swift`:
- Public `ACPV2InboundDelivery.Source`: `.stdio` or `.broker(provenance: ACPBrokerFrameProvenance, pendingRequestID: String?)`.
- Immutable receiptID/frame/connectionID/source. Public init(frame:connectionID:source:durableConsumptionAcknowledgement:), `decodeHeader() throws -> Header`, `acknowledgeDurableConsumption()`.
- Header exposes method:String, id:JSONRPCID?, params:LSPJSONValue?, rawValue:LSPJSONValue. Validate jsonrpc2/object/string method/no result/error and supported signed/string ID; leave params opaque, including absent/null distinction.

Modify `ACPStdioClient.swift` with public `incomingV2Inbound: AsyncStream<ACPV2InboundDelivery>` and private continuation. Finish it for v1 immediately and on drain. Finish legacy typed inbound method streams for v2 after initialization; do not finish stderr. Valid v2 methods yield exact evidence with lifetime-guarded callback, never enter legacy switch.

Modify `ACPRawBrokerTransport.swift` only at existing facade: store public `inboundDelivery: ACPV2InboundDelivery` once, retaining current fields and delegating acknowledge through the common token. No second broker stream or mapping task.

Tests: new `ACPV2InboundDeliveryTests.swift` for the new contract; extend existing `AlasTests/ACP/Protocol/ACPStdioClientTests.swift` and package `ACPBrokerRawClientTests.swift`. Temporary source-identical stdio/fake imports are permitted for rapid SwiftPM verification and removed before native checks.

## Review focus

- Request ID collision with an outgoing call must never settle that call. Task2.
- A valid header with malformed known params must remain opaque evidence, not execute or auto-answer. Task1/2.
- Duplicate keys/null IDs/mixed envelopes cannot acquire a guessed binding or consume a callback. Task1/2.
- Reading broker common views repeatedly and consuming facade/common concurrently must share one identity/token. Task3.
- Already-ACKed pending snapshots preserve original cursor and pending identity without new ACK or resolution authority. Task3.

## Task1: Common exact header and consumption contract

- [x] Add failing common-type tests for exact opaque params, signed/string/absent IDs, omitted/null params, malformed/ambiguous headers and duplicate/invalid UTF-8, plus copied/concurrent/reentrant single-use consumption and distinct equal captures. Observe missing-contract RED.
- [x] Implement immutable source/header/delivery with exact parser and existing signed/string ID interpretation. No typed method payload projection or reply API.
- [x] Run common/raw RPC/update delivery suites, inspect actual counts, record GREEN. No commit.

## Task2: Exclusive stdio raw method routing

- [x] Extend existing stdio suite with raw request/notification variants proving zero writes, zero legacy yields, exact bytes/params and no consumption. Add mode/lifetime capture tests and update colliding-ID regression to observe raw inbound evidence. Observe absent API RED and then behavioral RED before changing dispatch.
- [x] Implement raw stream and lifetime guard. Finish corresponding legacy v2 typed streams. Preserve update and RPC precedence and v1 generic switch. Valid inbound IDs never touch outgoing pending table.
- [x] Replace old v2 auto-consumption notification barriers with raw receipt observations or method-absent diagnostic barriers. Do not weaken ordering or lifetime assertions. Run full affected stdio/common/RPC/update suites, record GREEN. No commit.

## Task3: Broker compatibility and provenance

- [x] Extend existing broker suite for stable common-view UUID/bytes/provenance, shared facade/common consumption with reentry/concurrency, non-method diagnostic header failure, pending journal/snapshot metadata and already-ACKed unanswered restoration. Observe missing-view RED.
- [x] Store the common value once in each facade, preserve public fields and original callback authority, and delegate facade consumption. No transport/helper ownership or stream changes.
- [x] Run affected common/broker/helper/update/prompt owner suites with real counts, record GREEN.

## Task4: Final checks, review and tracking

- [x] Remove temporary harnesses. Run final affected package suites, full SwiftFormat lint and tracked/new-file whitespace checks. Attempt focused native stdio/connection/broker suites when feasible, recording actual counts and infrastructure failures distinctly.
- [x] One fresh whole-change review against fixed base, including untracked code/tests/docs. Fix material findings in one RED/GREEN pass, ledger deferred minors/declined behaviors, no rereview.
- [x] Update umbrella2213 with exact evidence and remaining request-ledger/recovery scope. Complete plan/ledger, preserving uncommitted branch until shipping requested.

## Preflight and rulings

Task1 public common value feeds Task2 stdio stream and Task3 broker view; signatures agree. Existing isolated worktree verified, no new worktree. Retain approved inline execution and focused repository checks rather than another execution menu, per-task commits or full-suite default. Source-private consumption helpers are not unified outside this feature.

## Completion evidence

- Common contract RED/GREEN: missing API followed by14 tests/3 suites passing.
- Stdio behavioral RED:1 definition failed with51 issues before exclusive routing;46 tests/4 suites passed after the change, including all existing stdio tests through temporary source-identical app copies with only the module import changed.
- Broker view RED/GREEN: absent stored view followed by97 tests/8 suites passing in the combined selection. Temporary app harnesses were removed.
- Final affected package selection:149 tests/13 suites passed. Full SwiftFormat lint:0/2710 files require formatting,1 skipped. Tracked/new-file whitespace checks pass.
- Native stdio/connection/broker checks are inconclusive: manifest-cache access was retried, then missing cached dependency manifests stopped Xcode before compilation. The completed xcresult reports unknown with0 total tests. No native, CI or live adapter/SSH pass is claimed.
- One fresh whole-change review found no Critical or Important findings. One Minor is deferred: late-frame assertions do not deterministically observe dispatch advancing past the injected late frame; the new inbound exit fixture also finishes its producer. Those assertions alone are not evidence of late-frame processing. Existing callback-lifetime, buffered receipt and stream-end checks passed. No production observation hook or unrelated transport change was added to repair a test barrier. No fix pass or rereview was needed.
- Review exclusions retained: atomic remote ACK revocation is outside the local lifetime contract; existing update-handle late acknowledgement semantics are unchanged; persistence/recovery/replies/execution/UI/live interoperability remain future work. Helper internals and unrelated Ghostty/research inputs were not changed.

The slice is locally implemented. Shipping was authorized after final verification; commit and PR publication follow the reviewed scope. Next: durable pending adapter-request retention/recovery and an explicit response owner, before production runner activation.
