# ACP 2 broker reply handoff implementation plan

> Use superpowers:executing-plans for the approved inline TDD workflow, with one fresh final review. Keep changes uncommitted until shipping is requested.

**Goal:** Write one exact broker reply for one original pending request, with factual generation-local retry outcomes.

**Architecture:** Add a lossless reply contract and generation-local attempt state in the helper, serialize exact writes with adapter stdin, then expose an attachment-fenced Swift facade through an additive capability-gated helper method. Existing v1 respond remains compatible.

**Tech stack:** Swift/Swift Testing, Rust/serde raw values, existing opaque payload wrapper and helper IPC.

**Spec:** [Approved design](2026-10-31-acp-v2-reply-handoff-design.md).

## Constraints and files

Base1a78acdd54d56438026658c04355690189538af1; branch nacho/acp-v2-reply-handoff. Preserve unrelated Ghostty/research. No SQLite, production runner, response owner or execution changes. No commits until requested. Production remains v1-only.

Create AlasHelper/src/acp_raw_reply.rs for exact envelope validation, contract types and generation-local attempt bindings; register in lib.rs. Modify acp_broker.rs for safe original pending lookup/resolution, acp_broker_process.rs for dispatch/write integration and writer poison, main.rs for capability. Existing protocol modules may re-export types as needed. Extend their existing tests, with module-local tests for this new state machine.

Create AlasPlatform/SSH/ACPBrokerRawReply.swift for params/result/status/rejection contracts; modify RemoteHelperProtocol.swift and RemoteHelperClient.swift for acpRawReplies:1 and respondExactACPBroker. Extend LocalACPBrokerService, ACPBrokerServicing, ACPRawBrokerTransport and ACPBrokerClient with the additive method. Create ACPRawReplyTests.swift for lossless Swift validation and extend ACPBrokerRawClientTests for concrete facade behavior. Extend existing helper tests if a package-accessible seam covers capability checks.

## Review focus

- ID reuse, including numeric/string collisions in helper pending keys: compare origin and original wire ID; retries cannot resolve successors. Task1/2.
- Concurrent retry after writer claim: return inFlight without waiting behind the same writer or writing twice. Task2.
- Partial write and flush failure: never publish resolution or allow later writes onto a possibly corrupt framed stream. Task2.
- Capability/lifetime awaits: never send through a replacement helper/client, classify lost response as uncertain. Task3.
- Duplicate/malformed envelopes and opaque numbers: no normalization or ambiguous envelope identity, exact UTF-8 metadata. Task1/3.

## Task1: Exact contract and original-request binding

- [x] Add regressions for existing raw respond premature resolution and stale ID targeting; observe RED. Add exact envelope cases and attempt binding tests before new APIs, observe missing-contract RED.
- [x] Add Rust RespondExactParams with brokerId/generation/pendingRequestId/originCursor/operationKey/frame/wireContext and ReplyResult echoing full identity plus inFlight/written/writeUncertain. Stable rejection codes invalid=-32077, stale=-32078, conflict=-32079, unavailable=-32080. Parse headers via RawValue, preserving opaque payloads; validate int32 errors, signed IDs, no CR/LF, exact original ID and bytes.
- [x] Add ReplyAttempts with lookup, claim and terminal finish, retaining operation/origin bindings across ACK pruning. Expose broker pending lookup and origin-checked raw resolution only after successful write. Keep legacy behavior separate.
- [x] Run locked helper module/broker tests and record GREEN; no commit.

## Task2: Helper dispatch and factual write outcomes

- [x] Add gated/injected writer tests for one write, concurrent retries, original-frame evidence, ID reuse, ACK pruning, pre/post-claim close, partial write/flush failure and poison. Observe missing behavior RED.
- [x] Add raw/respondExact IPC and acp/raw/respondExact routing. Lock order writer then runtime, preflight existing attempt lookup before waiting for writer, recheck under state lock before claim. Release state lock during I/O. Write bytes/newline/flush once, then resolve original origin and set written; failure sets writeUncertain and poisons all adapter writes. Leave pending evidence intact on uncertain.
- [x] Reject old raw respond at concrete helper boundary; v1 remains unchanged. Advertise acpRawReplies:1 only with the installed path. Run focused Rust suites plus routing/legacy regressions and record GREEN; no commit.

## Task3: Swift contract, capability gate and concrete facade

- [x] Add contract/parser/facade regressions before APIs. Verify exact payloads, explicit origin/operation, invalid input, foreign connection/context, duplicate retry result and lost-response uncertainty.
- [x] Add Swift Codable contracts and lossless envelope validation using LSPJSONValue in AlasACP; preserve full bytes via ACPBrokerRawJSONPayload in AlasPlatform. Add ACPBrokerServicing.respondExact with unsupported default for old test/service conformances, local forwarding and RemoteHelperClient capability checks tied to its helper generation. New API never falls back to old raw respond.
- [x] Expose ACPBrokerClient.respondToRawRequestExact(expectedConnectionID:params:) -> typed result through raw actor. Validate identity/cancellation before dispatch, exact returned binding after await, report transport/result uncertainty without implying upstream consumption. Pre-handoff typed rejections remain distinct. Old raw facade responds unsupported before sending.
- [x] Run affected package suites first, inspect counts. Run Rust locked tests, full SwiftFormat and scoped rustfmt/whitespace. No native build unless app files change.

## Task4: Review and completion

- [x] One fresh whole-change review against fixed base, including new files and excluding unrelated inputs. One material RED/GREEN fix pass if needed, no rereview.
- [x] Record verified counts, rulings, remaining limitations and umbrella status. No live helper/adapter/SSH or production activation claim. Leave changes uncommitted for shipping authorization.

## Preflight rulings

Approved design explicitly continues inline execution after planning, so no execution menu or repeated approval gate. Focused repository verification overrides generic whole-repository test defaults. Generation-local attempt memory is intentionally retained until supervisor exit; crash durability and reply authorization remain future work.

## Completion evidence

- Unfenced failed-write regression and missing contract/API RED observed before implementation. Shared17-case envelope corpus preserves accepted payload bytes in Swift and Rust.
- Final affected package selection:169 tests/16 suites GREEN. Final affected Rust selection:49 tests GREEN. Explicit broker protocol/crash-recovery suites:60 tests/2 suites GREEN. A real pipe pins exact bytes plus newline and raw resolution evidence; a real helper with a512KiB blocked pipe pins concurrent retry and close routing.
- Full SwiftFormat lint:0/2720 require formatting,1 skipped. Scoped Rust formatting and whitespace checks passed. No app files changed; no native app build or live adapter/SSH qualification is claimed.
- One fresh review found2 Important and2 Minor findings. Both Important findings reproduced RED and passed after one fix pass: outer helper/IPC queues blocked reply retries and close; post-poison sends created orphan pending operations on retry. The fix keeps exact replies independently routable, rechecks claims while waiting for stdin, and rejects poison before operation registration. Already registered competing sends settle uncertainly. No rereview.
- Deferred Minor: Swift's existing lossless JSON object parser rejects canonically equivalent distinct keys inside opaque result/error data, and exact nested duplicate keys. Rust leaves these opaque. Accepted frames remain byte-exact; rare otherwise-valid payloads may be rejected before handoff.
- Deferred Minor: Rust serde integer decoding rejects signed-zero ID/error-code tokens while Swift accepts them. Align these validators before production qualification.

Choices retained: broker-only boundary first, and adapter/writeUncertain ends inbound observation so callers must deliberately reconcile a lost attachment. Generation-long attempt retention costs memory and provides no crash/cross-generation write guarantee. Scope exclusions accepted by review: direct stdio, current-request/response authorization and durable intent, runner/UI/execution/production activation, adapter receipt/model consumption, live adapter/SSH qualification, performance/resource guarantees, and unrelated Ghostty/research.

Shipping was authorized after implementation. Umbrella2213 tracks this local contract separately from the remaining response owner and production work.
