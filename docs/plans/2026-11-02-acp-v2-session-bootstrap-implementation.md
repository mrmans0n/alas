# ACP v2 fresh-session bootstrap implementation plan

> Execute inline with superpowers:executing-plans. The approved design authorizes planning and implementation without another approval menu. Leave changes uncommitted until shipping is requested.

**Goal:** Initialize a fresh v2 attachment, bind a newly created upstream session durably, and install the attachment runtime without stale effects or repeated setup.

**Architecture:** Separate wire contracts and concrete-client single-use bootstrap claims in AlasACP. A lease-fenced binding transaction and MainActor coordinator in AlasSessions preserve original queued ingress and delegate established-session behavior to the runtime.

**Spec:** `docs/plans/2026-11-02-acp-v2-session-bootstrap-design.md`

## Global constraints

Production remains v1-only. Fresh-session bootstrap only, no resume/adoption/auth execution/UI/runner activation/schema or automatic fallback. Exact captured evidence and existing ACK rules remain authoritative. Deadline/cancellation settles callers without waiting for blocked dependencies. Preserve unrelated Ghostty/research. One fresh final review and one combined material fix pass, no rereview. No commits before shipping request.

## Review focus

- An old open snapshot cannot authorize another initialization; concrete transport claim must reject previous sends and duplicate coordinators. Task 2.
- Cancelling a caller during a dependency that ignores cancellation cannot permit a late dispatch, ACK or runtime install. Task 3.
- Real setup binding COMMIT precedes response consumption, and malformed/conflicting/stale proof never authorizes installation. Tasks 1/3.
- Original traffic queued before setup must survive intact without competing stream consumers or fabricated session IDs. Task 3.
- Fresh broker open may have unsolicited journal frames; adopted=false, not empty journal tail, establishes fresh process provenance. Task 2/3.

## Task 1: Wire contracts and atomic local binding

Files: extend `ACPInitialization.swift`; new `AlasACP/ACP/Protocol/ACPV2SessionSetup.swift`; extend negotiation tests. Add store/persistence bootstrap binding method and typed receipt in AlasSessions; exercise through real SQLite in new `ACPV2SessionBootstrapTests.swift`.

Interfaces: `ACPV2SessionNewParams(cwd:mcpServers:)`, strict `ACPV2SessionNewResult.decode(Data)` retaining raw bytes/value and real ID; `validate` requires session and per-MCP-transport object capabilities. `bindV2FreshSession(upstreamSessionId:source:fence:)` returns committed binding receipt. Source is existing `ACPV2InboundLedgerSource`; compare nil existing remote ID, current lease and broker source context, forbid recovery/archived/missing rows and prior v2 streams. No full-row upsert.

- [x] Write missing-contract RED for exact params/raw results, invalid IDs and capability markers, atomic binding/SQL rollback/lease conflict and refusal to overwrite an existing binding.
- [x] Implement wire types and narrow transaction plus actor forward, no schema change.
- [x] Run focused schema/bootstrap suites; inspect nonzero counts and GREEN.

## Task 2: Single-use concrete bootstrap claims

Files: new `ACPV2BootstrapClaim.swift`; extend `ACPStdioClient.swift`, `ACPRawBrokerTransport.swift`, `ACPBrokerClient.swift`; extend bootstrap and existing raw broker suites.

Interfaces: opaque `ACPV2BootstrapClaim`, `claimV2Bootstrap()` for stdio and `claimV2Bootstrap(opened:)` for broker; `sendV2Bootstrap(_:claim:authorize:) async throws -> ACPResponse`. Claims bind concrete state, reserve initialize then session/new exactly once. Existing startup sends mark attachment used; claimed clients reject unclaimed startup sends. All v1 behavior unchanged. Final handoff checks cancellation/claim/current predicate. Broker claim compares the actual saved open result plus fresh process metadata, rejects adopted/cached/prior operations, permits unsolicited tail. No retry/recovery exception.

- [x] Write RED for prior-send/duplicate/foreign claim refusal and one initialize/create, plus broker actual-open provenance.
- [x] Implement claim at actual client/actor dispatch boundary, cancellation-aware stdio pending removal for bootstrap only; keep ordinary request paths unchanged.
- [x] Run claim/bootstrap/raw broker/negotiation suites GREEN.

## Task 3: Coordinator and event-gated integration

Files: new `AlasSessions/ACP/Session/ACPV2SessionBootstrap.swift`, extend runtime tests only if shared fixture is necessary, extend bootstrap and broker suites.

Interfaces: concrete `Attachment` constructors, separate `initialize(operationKey:)` and `createSession(params:operationKey:)`, typed initialization and installed-session evidence, current status stream, stop. Constructor takes local session/fence/persistence/journals/current predicate/onRequest and an injected absolute deadline wait. Public operations single-flight and explicit; v1 result is replacement-required. A private task owns dependency work and a synchronous cancellation latch plus MainActor waiter settlement withdraws caller authority before any late return. Stop owns installed runtime lifetime but never closes transport.

- [x] Write missing-coordinator RED using real client routing and SQLite: early request/update+setup, binding visible inside ACK, ready runtime answers original capture, no completion from initial idle.
- [x] Implement explicit init/create/install phases, raw evidence validation, claimed sends and binding before setup ACK. Leave existing facade queues to the runtime's sole consumers.
- [x] Add event-gated RED for cancellation/stop/deadline/lease loss at response/binding/restore boundaries, duplicate operations, malformed setup and uncertainty no-resend.
- [x] Implement prompt settlement and final authority checks; run combined affected package selection GREEN.
- [x] Add broker fixture integration checking early cursor protection and fresh/adopted distinction; run GREEN. Record limits and any justified interface ruling.

## Task 4: Final verification and one review

- [x] Run affected package suites and SwiftFormat/whitespace checks, inspect actual counts. No entire local plan or native app build for package-only changes.
- [x] Supply fixed baseline, all tracked/new-file diffs, design/plan/ledger to one fresh read-only reviewer. Include Review focus verbatim.
- [x] Regrade findings by effect. Reproduce Critical/Important RED, fix together and run affected suites GREEN. Record declined judgments and deferred Minors; no rereview.
- [x] Update evidence/design/umbrella as appropriate and report exact checks, limits and remaining uncommitted work.

## Execution evidence and rulings

Task1 wire/binding contract RED then GREEN9/2. Task2 claim contracts RED then GREEN47/4. Typed Sendable request cases avoid unchecked erased-request transfer. Existing completion-memory regression caught snapshot retention; only eligible fresh snapshots are saved and cleared on claim. Ordinary v1 cancellation behavior remains unchanged.

Task3 missing coordinator RED, then concrete regressions pinned missing fresh idle default, wrong local broker session, synchronous early-offer cancellation, stale bootstrap ready status after runtime EOF, and native Windows drive paths. Initialization source responses remain inspectable even on schema failure. Latest-only runtime status gets a single continuing coordinator monitor after installation, not another facade ingress consumer.

Ruling: update and request journals commit independently; readiness is restored-owner readiness, not a cross-stream drain barrier. Assertions await actual state application. Fresh default idle is applied through setupDefault before ingress, never as a fabricated persisted frame. The absolute deadline governs bootstrap rather than the installed runtime's later lifetime. Setup config/command data remains uninterpreted evidence, not UI support.

Pre-review affected package run passed124 tests/10 suites in `/private/tmp/alas-bootstrap-review-input.log`. No app/native/CI/live adapter/SSH qualification is claimed. Implementation is uncommitted.

## Final review fix pass

One fresh final review found0 Critical,4 Important and0 Minor findings. The combined RED run `/private/tmp/alas-bootstrap-final-red.log` reproduced all4 definitions with11 issues: cancelled entry left an active phase; a queued stdio initialize physically wrote after cancellation behind another serialized write; a real binding receipt from another database authorized ACK/install; empty/relative MCP executable paths consumed setup attempts.

Fixed in one material pass, with no rereview. Entry cancellation now goes through terminal failure handling. Bootstrap stdio dispatch uses the existing factual frame-writer authorization boundary after serialization and a synchronously invalidated one-shot gate; ordinary send retains its previous behavior. Only the actual RPC response settles successful setup. Binding receipts carry configured store path and exact lease identity and are checked before ACK or runtime installation. MCP executable paths use the same native absolute-path validation as cwd, allowing callers to correct invalid input before dispatch.

Strengthened existing variants pinned reentrant claim invalidation for both stdio and broker and canonically equal but byte-distinct lease identities. The new binding transaction verifies owner/token BLOB bytes rather than inheriting the generic fence helper's Swift String equality; receipt checks also compare exact UTF-8. A final lifecycle variant reproduced a runtime stopped inside the last current predicate; actual runtime status is rechecked before publishing success. These complete the same handoff/proof/lifecycle fix pass. They add no new test definitions or second review.

Ruling: store authority proof uses the exact configured path and lease bytes. Path aliases are conservatively rejected; callers should use the intended persistence actor. This is commit consistency proof, not authentication of a malicious persistence implementation or cross-process I/O atomicity.

Accepted declined judgments: resume/load/fork, adoption and uncertain-operation recovery; authentication execution, UI, runner activation, queue advancement and cleanup RPCs; live adapters, native integration, SSH and publication eligibility; cross-process exactly-once/SQLite-transport arbitration; detecting arbitrary external AsyncStream consumers; sustained startup buffer memory bounds; config/command/unknown metadata interpretation; unrelated Ghostty/research. These remain excluded or unverified, not inferred successes. SQLiteKit's embedded-NUL text preservation and non-NULL corrupt binding rejection were inspected without a finding. No Minor findings were deferred.

## Final verification and handoff

Final affected package selection passed134 tests/11 suites in `/private/tmp/alas-bootstrap-complete.log`, including the actual serialized frame writer. Full SwiftFormat lint passed0/2767 files requiring formatting,1 skipped in `/private/tmp/alas-bootstrap-lint-complete.log`; tracked and new-file whitespace passed. No code changed after this run. No app build, CI, published-adapter, live or SSH result is claimed. Production remains v1-only. Implementation remains uncommitted on `nacho/acp-v2-session-bootstrap`.

The umbrella #2213 merge/validation update was prepared but automatic approval review rejected the write because overwriting the shared roadmap requires explicit authorization. The issue remains unchanged. Proposed note is in the local execution record; no alternate tool or indirect write was attempted after the rejection was identified.

- [ ] Apply the proposed #2213 update only after explicit user authorization.
