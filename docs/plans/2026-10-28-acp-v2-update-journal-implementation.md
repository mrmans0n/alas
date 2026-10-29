# ACP 2 update journal implementation plan

> **For agentic workers:** Use superpowers:executing-plans with the established native inline method, TDD per task, and one fresh final review. Keep changes uncommitted until shipping is requested.

**Goal:** Durably retain exact v2 update receipts and replay them passively without activating the v2 runner or consuming transport handles.

**Architecture:** Add stable delivery receipt IDs and a journal domain in AlasSessions. The existing session store owns additive SQLite tables; the persistence actor forwards required lease-fenced registration/append and bounded reads. All journal rows remain separate from message projection and broker ACK state.

**Tech stack:** Swift, SQLite, Swift Testing, existing AlasCore module boundaries.

**Spec:** [Approved design](2026-10-28-acp-v2-update-journal-design.md).

## Global constraints

- Branch `nacho/acp-v2-update-journal`, base `e8323d19ca31c7e0c4085fa56e003f098ac86072`, existing isolated worktree. Preserve unrelated research. No commits/PR before shipping authorization.
- `session/update` receipts only. Production supported versions stay v1-only. No runner/UI activation, RPC outcomes/pending-request durability, upstream resume, SSH replication or compaction.
- Never parse/re-encode stored frames or deduplicate equal payloads. Registration/append require a current matching writer lease; no nested transaction under `withLeaseFence`.
- Broker identity is ID/generation/raw-v2 context, excluding mutable ACK. Preserve the first registration baseline across reopen/ACK changes. Receipts never invoke or reconstruct consumption callbacks.
- Journal domain values live together in AlasSessions so the successful durable-receipt initializer can remain internal to the persistence module. Delivery IDs remain in AlasACP.
- Oversized replay policy: return one oversized first record with `containsOversizedRecord = true`; otherwise stay within count and byte budgets. Defaults 128 records/1MiB, record-count maximum 1000 and byte-budget maximum Int32.max; reject nonpositive or excessive budgets.

## Files and responsibilities

- Modify `Packages/AlasCore/Sources/AlasACP/ACP/Protocol/ACPV2SessionUpdateDelivery.swift`: one fresh immutable receipt UUID per new delivery, preserved by copies.
- Modify `Packages/AlasCore/Sources/AlasFoundation/SQLiteKit/SQLiteStatement.swift` only if empty-BLOB regression proves necessary.
- Create `Packages/AlasCore/Sources/AlasSessions/ACP/Session/ACPV2UpdateJournal.swift`: public immutable source/stream/record/receipt/continuation/page values and typed errors; durable receipt init internal.
- Create adjacent `ACPSessionStore+V2UpdateJournal.swift`: schema helper, validated registration/append, strict row loading and byte/count-bounded paging. Tables belong to the existing DB, with session-delete cascade and no replica triggers.
- Modify `ACPSessionStore.swift`: next migration version31 and call journal schema creation before publishing schema version.
- Modify `ACPSessionPersistence.swift`: public actor entry points forwarding the store contracts.
- Extend existing delivery, store schema/CRUD and persistence suites; new files only for genuinely new journal domain behavior, not scenario-sliced store siblings.

## Review focus

- Stdio copies retry once, but separate equal chunks both survive; broker retries across connection/origin changes retain one original event. Task1/2.
- ACK advances or an existing stream reopens at a higher ACK; it must not reset its initial baseline or reject valid appends. Task2.
- A stale lease, changed generation/context, conflicting source identity or SQL failure must not return a durable receipt or leave an inserted row. Task2.
- Pagination cannot load an unbounded set of blobs, stall on a large first frame, mix continuations between streams or claim a complete upstream prefix. Task3.
- Replayed historical idle/running data must not acquire ACK authority or emit a new completion. Old generations survive broker clear while session deletion removes their rows. Task3.

## Task1: Delivery identity and byte-storage assumptions

Interfaces: `ACPV2SessionUpdateDelivery.receiptID: UUID`, assigned once by construction; no caller override. Existing callback/connection/provenance semantics unchanged.

- [x] Extend `ACPV2SessionUpdateDeliveryTests.copiedHandlesAcknowledgeOnceAndAllowSynchronousReentry` to pin shared receipt identity on copies and distinct identity for a separate equal-byte delivery, alongside existing single-use consumption behavior.
- [x] Extend existing `SQLiteDatabaseTests` with an empty Data BLOB binding round-trip checking `typeof(value) == "blob"` and `length(value) == 0` rather than accepting SQL NULL. Run the focused package tests and observe RED.
- [x] Implement stable identity and the smallest demonstrated empty-BLOB fix; preserve nonempty binary behavior and existing transaction semantics.
- [x] Run delivery/SQLite suites with actual selected test counts. No task commit.

## Task2: Atomic registration and durable append

Interfaces in `ACPV2UpdateJournal.swift`:
- `ACPV2UpdateJournalSource`: `.stdio(connectionID: UUID)` or `.broker(id: ACPBrokerID, generation: ACPBrokerGeneration)`.
- `ACPV2UpdateJournalStream`: immutable UUID id, local/upstream session IDs, source, format/context and optional initial broker cursor. Constructed by store registration/load, not a mutable active-owner handle.
- `ACPV2UpdateJournalRecord`: stream ID, positive Int64 ordinal, original delivery receipt UUID/connection UUID, optional original broker provenance, exact frame Data.
- `ACPV2UpdateJournalReceipt`: successful committed record plus `wasInserted: Bool`, internal initializer, no callback. Replay returns records, never this type.
- `ACPV2UpdateJournalError`: typed invalid-input, stale-lease, incompatible-stream, conflicting-receipt, unsupported-format and corrupt-record errors.

Store/actor methods:
- `registerV2UpdateJournal(sessionId: String, upstreamSessionId: String, source: ACPV2UpdateJournalSource, fence: ACPSessionLeaseFence) throws -> ACPV2UpdateJournalStream`.
- `appendV2Update(_ delivery: ACPV2SessionUpdateDelivery, to stream: ACPV2UpdateJournalStream, fence: ACPSessionLeaseFence) throws -> ACPV2UpdateJournalReceipt`.

Storage decisions: unique stream on local session plus canonical source key; upstream ID is immutable and mismatched reopen is a conflict. Stream table has format1/raw-v2 context and source fields, baseline captured only on insert. Record table uses `(stream_id, ordinal)` and unique `(stream_id, receipt_key)`, with exact BLOB and original delivery/provenance metadata. Broker receipt key is its positive event cursor; stdio key is delivery receiptID. Allocate next per-stream ordinal inside the lease transaction. Limit raw frame count to the SQLite binder's supported size before conversion; database limits still surface as errors.

- [x] Add failing existing store/persistence regressions for registration/reopen, exact byte append/retry after DB reopen, same-key conflicting bytes, repeated equal stdio chunks, broker reattachment with changed connection/origin, ACK advancement preserving baseline, required stale-fence rejection and descriptor replacement rejection.
- [x] Add migration30→31 case to existing schema suite, preserving legacy rows and checking no journal writes from ordinary v1 operations. Run focused package first; source-identical temporary app-suite harness is permitted for rapid RED/GREEN and removed before final native checks.
- [x] Implement values, migration, store and actor entry points. Validate current DB stream on every append, exact fence/session match, source/context/upstream identity and integer ranges. Do not validate frame contents. Return receipt only after the lease transaction commits.
- [x] Confirm no callback fires on success, duplicate, rollback, replay or rejected write; callers may explicitly consume their original live handle after committed receipt. A trigger-induced insert failure proves rollback/no partial ordinal allocation. Concurrent copies of one receipt converge to one row.
- [x] Run affected package/store/persistence suites; inspect counts, record results. No task commit.

## Task3: Bounded passive replay and lifecycle retention

Interfaces:
- `ACPV2UpdateJournalContinuation(streamID: UUID, afterOrdinal: Int64)` validates positive positions and stream ownership when read.
- `ACPV2UpdateJournalPage`: records, optional next continuation, `isAtEnd`, `hasKnownMissingPrefix`, `containsOversizedRecord`.
- Store/actor `loadV2UpdateJournalPage(stream: ACPV2UpdateJournalStream, after: ACPV2UpdateJournalContinuation? = nil, maxRecords: Int = 128, maxBytes: Int = 1_048_576) throws -> ACPV2UpdateJournalPage`.

First query only row lengths/ordinals up to count+1; choose the byte-limited prefix with one oversized-first progress policy, then load only selected blobs. Continuations are local retained-journal positions, not helper ACK cursors or completeness proofs.

- [x] Add failing replay cases to existing suites: count/byte pages with exact continuation order, oversized-first progress, cross-stream/invalid continuation rejection, empty Data, unsupported stored format and corrupt receipt metadata. Include known missing prefix from baseline>0 and unchanged baseline after ACK.
- [x] Replay retained known message/activity fixtures into the existing session owner and compare canonical facts; use `.snapshot` for historical state updates, retaining raw unknown/malformed frames without any ACK callback or foreground-completion claim. Do not add a production projection/replay runner.
- [x] Add existing-store retention regression: clear broker tuple or register a new generation retains old records; actual session deletion cascades. No journal table enters replica export.
- [x] Implement strict validated paging; reads never require or mint a writer/ACK authority, and never mutate journal, row ACKs, queues or model state.
- [x] Run affected package and native schema/CRUD/persistence suites. No task commit.

## Task4: Final verification and tracking

- [x] Full SwiftFormat lint, tracked/new-file whitespace checks, and final affected package/native suite checks with actual counts. No full app test plan by default.
- [x] One fresh whole-change review against the fixed base, including untracked source/tests/docs and excluding unrelated research. Fix material findings in one RED/GREEN pass, no rereview; ledger decisions/deferred minors.
- [x] Update umbrella2213 as locally implemented with exact evidence and excluded scope. Complete plan/ledger. Preserve branch/worktree without commit, push or PR until requested.

## Preflight and execution rulings

- Approved design supplies source identity, byte authority and ACK separation consumed by Tasks2/3; receipt and replay values share one module to keep receipt construction controlled. Lease-fenced operations already own a transaction; schema initialization is separate. No interface conflicts found.
- Retain the established approved inline method; do not add a second execution-menu approval. Repository policy's focused checks take precedence over generic full-suite instructions. Costs: adjust decomposition if needed, while keeping the approved semantics.
- Pure ordered ingestion is a caller contract; this slice does not build a new receiver/runner actor. The successful receipt only proves storage, never callback authority.

## Execution evidence

- Baseline: 11 tests/3 suites passed. Delivery identity and SQLite boundary checks: 8/2 passed. Empty Data already binds as BLOB; no binder change was needed.
- Registration/append: 76 tests/4 suites passed, including source-identical temporary app suites. Replay: 96 tests/6 suites passed after correcting the malformed JSON fixture's concrete error-type assumption.
- Temporary app-source harnesses are removed before final native checks. The final review found 1 Important gap: historical streams needed passive discovery after restart/descriptor clear. The single fix pass adds `loadV2UpdateJournalStream(sessionId:beforeStreamID:)` on store/persistence, returning one latest-first stream per call with a session-bound continuation, independent of lease/current descriptor. Reopen-after-clear and lease-replacement regression pins this contract. No second review or deferred minor finding.
- Mutations use the existing lease transaction; paged reads/discovery use a short SQLite snapshot. Stream/context/receipt identity stays validated, while current ACK advancement never resets baseline.

The historical-discovery fix passed 52 tests/4 suites. Final affected package verification passed 46 tests/7 suites. Full SwiftFormat lint reported 0/2661 files requiring formatting, 1 skipped. Final native schema/CRUD/persistence verification passed 77 definitions / 107 executions, with no failures or skips. No temporary harnesses remain and production sources are stable.

## Execution rulings

- retain approved inline execution and proceed after full-design approval without another execution menu. No commits until shipping is requested. Cost if wrong: adjust decomposition while preserving the approved semantics.
- journal domain values live in AlasSessions to keep durable receipt construction module-internal; existing delivery remains in AlasACP. Cost if wrong: future consumers import the persistence-domain module for receipt values.
- one oversized first replay record makes progress with an explicit flag; maximum count1000, defaults128/1MiB. Cost if wrong: callers must explicitly handle a single frame exceeding the byte budget.
- retain the narrow empty-BLOB boundary characterization without a production binder change because it already passes. Cost if wrong: platform-specific binder behavior will be caught by this journal prerequisite test rather than an unnecessary rewrite.
- replay reads use a short SQLite snapshot transaction for consistent metadata-length selection and blob fetches, while mutations alone use required lease fences. Cost if wrong: read transactions hold a bounded snapshot until a page is materialized.
- historical stream discovery is bounded to one metadata record per call, newest first, using a session index and stored rowid order. Cost if wrong: callers iterate history rather than receiving an unbounded list; no frame or ACK authority is created.

## Final evidence and handoff

- Final native xcresult: **Passed, 77 test definitions / 107 executions across store schema/migrations, CRUD and persistence, zero failures/skips**. Result: `/private/tmp/alas-journal-app-final.xcresult`.
- Final package check: **46 tests in 7 suites passed**. Log: `/private/tmp/alas-journal-package-verified.log`.
- Full SwiftFormat lint: **0/2661 files require formatting, 1 skipped**. Tracked/new-file whitespace checks passed. No temporary app-source harness remains.
- [Umbrella #2213](https://github.com/mrmans0n/alas/issues/2213) records this slice as locally implemented, pending commit/PR/merge, with CI and live ACP2/SSH results unclaimed.
- The one material review finding was fixed and verified in one pass. No second review or deferred minor findings.
- Keep branch `nacho/acp-v2-update-journal` and this worktree local and uncommitted until shipping is requested. The unrelated adapter research file remains excluded. The approved keep-local and focused-test workflow takes precedence over the generic finishing skill's integration menu and full-suite suggestion.
