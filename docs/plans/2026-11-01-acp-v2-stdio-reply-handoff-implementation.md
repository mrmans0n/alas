# ACP 2 stdio reply handoff implementation plan

> Use superpowers:executing-plans for the approved inline TDD workflow, with one fresh final review and one material fix pass if needed. No commits until shipping is requested.

**Goal:** Reply once to an actual current stdio capture with accurate local write facts, cancellation and source fencing.

**Architecture:** An opt-in factual frame writer in AlasFoundation serializes transport writes off MainActor. A lock-owned registry in AlasACP records actual captures and immutable reply attempts; ACPStdioClient integrates registration, explicit handoff and lifetime invalidation without changing receipt consumption or production selection.

**Tech stack:** Swift, Swift Testing, existing raw envelope validation and process transport.

**Spec:** [Approved design](2026-11-01-acp-v2-stdio-reply-handoff-design.md).

## Global constraints and files

Base aa95d477b5db52074aef91ddfeb128e767d2b0eb, branch nacho/acp-v2-stdio-reply-handoff. Preserve Ghostty/research. No helper/Rust/schema, production runner/UI/queue or response authorization/intent changes. Production remains v1-only. Keep connection-lifetime attempt facts and response bytes; do not cache request frame history.

Create AlasFoundation/JSONRPC/JSONRPCFrameWriter.swift for opt-in public JSONRPCFrameWriting/write result and an internal serialized writer with injected I/O. Modify JSONRPCStdioTransport.swift to use it for shared write serialization, async factual writes and independent termination. Create package JSONRPCFrameWriterTests.swift for the new unit, event gates and real pipe boundary.

Create AlasACP/ACP/Protocol/ACPV2StdioReply.swift for public key/status/proof/errors and internal captured-origin/attempt state. Modify ACPStdioClient.swift for actual registration, async respondToV2Request and stop/legacy responder fences. Extend existing app ACPStdioClientTests.swift and fake; temporary import-only package copies can validate these exact sources. Avoid scenario sibling suites for the same client.

## Interfaces

JSONRPCFrameWriting.writeFrame(_ data: Data, authorize: @escaping @Sendable () -> Bool) async -> JSONRPCFrameWriteResult, cases notWritten/written/writeUncertain(String). Internal JSONRPCFrameWriter.init(write: @escaping @Sendable (Data) throws -> Void), send(_ framed: Data) throws, writeFrame(_:authorize:) async -> result, close() synchronously invalidates without its writer lock. The concrete transport applies its existing framing once.

ACPV2ReplyOperationKey uses exact UTF-8 equality/hash. ACPV2StdioReplyStatus cases queued/inFlight/written/writeUncertain/notWritten. ACPV2StdioReplyResult contains connectionID, receiptID, requestID, operationKey, status with exact identity comparison. ACPV2StdioReplyError distinguishes unsupported, invalidOrigin, invalidFrame, invalidOperationKey, conflict, invalidated.

ACPStdioClient.respondToV2Request(_ delivery: ACPV2InboundDelivery, expectedConnectionID: UUID, operationKey: ACPV2ReplyOperationKey, frame: Data) async throws -> ACPV2StdioReplyResult. Registry supports register(actual delivery,id), reply(...writer), authorize, finish, cancel and stop. Only actual captured receipt IDs register; request IDs/keys index by exact byte identity. State lock is never held during writer acquisition/I/O. Current wire slots are active(receipt) or ambiguous; attempts carry immutable binding, status and at most one waiting continuation. Identical retries query facts without another write.

## Review focus

- Incoming/outgoing equal IDs and canonical-equivalent string IDs/keys remain separate. Task2/3.
- Cancellation before insertion, after queueing, at authorization and before completion cannot double-resume or permit resend. Task2/3.
- Successor capture during finalization survives old completion; only unanswered unclaimed/queued duplicates become ambiguous. Task2/3.
- A blocked exact write plus ordinary send/notify cannot make shutdown wait on a writer/actor queue. Task1/3.
- Partial failure poisons all writes and settles queued/claimed attempts correctly, without consumption. Task1/3.

## Task1: Factual serialized writer

- [x] Add failing tests for opt-in authorization, exact bytes, invalidation while waiting, write failure poison and serialized sync/async writes. Observe missing-contract RED.
- [x] Implement the narrow protocol/result and internal writer. Use a connection worker for async I/O and one writer lock for all sends. Close uses separate lifetime state and never waits for I/O; reject before write if closed/poisoned or authorization fails. Any started I/O error poisons later writes. Wire concrete process transport to existing framing and independent close/exit invalidation.
- [x] Verify with selected package writer/framer suites. Add real isolated pipe/process test for blocked writer, queued ordinary send and termination, with event/deadline synchronization and exact byte assertions. Observe regression where necessary and GREEN. No commit.

## Task2: Captured origin and attempt lifecycle

- [x] Add missing-API client tests for actual captures/copies, explicit key/bytes, foreign/invented/notification/v1 handles and retries. Observe RED using import-adjusted exact source copies.
- [x] Implement metadata-only origin registry and public facts. Atomically register the once-constructed inbound delivery before yield. Validate source, connection, response ID/envelope and current unambiguous capture; explicit key binds origin/response bytes. Queue one worker; authorize immediately before actual I/O; finish by origin, preserving successors. Known retries return facts before current-origin lookup; new calls on closed client reject.
- [x] Integrate stop at the client lifetime boundary and guard legacy ID-only responders in v2. No inbound ACK from reply work. Run affected package/client suites and inspect counts. No commit.

## Task3: Race, failure and concrete transport evidence

- [x] Extend existing client tests with before/after-claim cancel/stop gates, prompt namespace collisions, byte-distinct IDs/keys, invalid frames/proofs, successor during finalization, queued/unclaimed ambiguity, notWritten retry/new-key behavior, uncertain poison and late completion. Existing guards may be characterized rather than removed to manufacture RED.
- [x] Verify first cancellation settles promptly while I/O is gated; copied retries do not enqueue another writer; explicit fresh key works only after terminal notWritten on a current origin. Consumption is independent in both orders. Unsupported custom transport cannot fall back to send/onWritten.
- [x] Run affected package suites first, then attempt focused native stdio tests with isolated DerivedData. Missing dependency/cache failures are inconclusive; use exact source import-adjusted harness as supplementary evidence and remove it afterward. Do not repair unrelated infrastructure.
- [x] Full SwiftFormat and scoped whitespace checks, with actual suite counts. No commit.

## Task4: Final review and completion

- [x] One fresh whole-change review against fixed base including new files, excluding unrelated inputs. One material RED/GREEN fix pass if needed, no rereview.
- [x] Record evidence, rulings, deferred minors and umbrella progress. Preserve existing opaque-object and broker signed-zero qualification limitations. No production/live adapter/SSH claim. Leave uncommitted until requested.

## Preflight rulings

Approved design explicitly continues inline after planning, so no second execution menu or approval gate. Focused repo checks override generic whole-repository test defaults. Task1's no-ACP writer contract feeds Task2's attempt controller; capture registry and Foundation worker use independent locks, with writer-before-registry order at authorization. Task3 gates those interfaces rather than adding a second receive stream. No shared-interface conflict.

## Verification evidence

- Exact app test sources with only their module import changed passed with the affected package selection: 229 tests in 21 suites, `/private/tmp/alas-stdio-reply-eof-confirmed.log`. Temporary copies were removed.
- The repository state without temporary copies passed 187 tests in 20 affected package suites, `/private/tmp/alas-stdio-reply-package-verified.log`.
- Full SwiftFormat lint passed, 0/2742 files requiring formatting, 1 skipped, `/private/tmp/alas-stdio-reply-lint-final.log`. Tracked whitespace checks passed.
- Native focused stdio validation stopped before compilation because cached dependency manifests were missing, `/private/tmp/alas-stdio-reply-native.log`. No native test, CI or live adapter pass is claimed.

Shared transport EOF exposed pending-call hangs in v1 ACP and helper consumers. Failing regressions preceded generation-fenced helper cleanup and common ACP observation-end draining. EOF carries no invented process exit status. Concrete shutdown assertions await observation end, which may precede an actual exit event.

## Final review and rulings

One fresh read-only whole-change review found no Critical or Important findings. No material fix pass or rereview was needed. One Minor is deferred: add direct coverage showing cancellation of an identical concurrent query cannot cancel the first caller's attempt. The implementation's caller nonce prevents this; the reviewer found no defect.

Rulings made during execution, in order:

1. Keep capture/attempt metadata private and use a distinct nonce per invocation, so a copied query cannot cancel the original waiter. This preserves attempt ownership; using one token would let a cancelled query disarm someone else's queued reply.
2. End an unusable connection on synchronous or asynchronous I/O failure. Real-pipe RED evidence showed the writer could become poisoned while observation remained open. This also ends v1 connections whose input pipe is already unwritable.
3. Treat physical EOF as observation loss and drain v1/v2 ACP plus generation-matched helper calls without inventing an exit status. RED evidence showed pending continuations otherwise hung. Concrete shutdown tests await observation end because EOF can precede an exit event.
4. Keep the native dependency-cache failure inconclusive and do not repair unrelated infrastructure. Exact-source package validation supplements it but does not prove an app build.

Reviewer declined judgments accepted:

- Shared opaque-object key behavior and broker signed-zero remain tracked qualification limitations. Neither changes in this slice.
- Durable intent, persistence, semantic authorization/execution, production selection and UI belong to later slices. Receipt capture and write facts grant none of that authority.
- Live adapter/SSH and native app qualification remain unverified; do not infer them from fixture passes.
- Restarting the same stopped client is unsupported; create a new connection identity. Registry/writer closure remains permanent.
- Unrelated Ghostty and adapter research remain untouched.

The cost of these boundaries is explicit remaining qualification and integration work before v2 eligibility. Production remains v1-only. Changes remain uncommitted until shipping is requested.
