# ACP 2 inbound ledger implementation plan

> **For agentic workers:** Use superpowers:executing-plans with the approved inline method, meaningful TDD and one fresh final review. Keep changes uncommitted until shipping requested.

**Goal:** Commit exact inbound receipt evidence and recover bounded historical pages without minting consumption or response authority.

**Architecture:** Add schema33 stream/record tables to the existing session store, immutable journal-domain values in AlasSessions and public persistence-actor entry points. Writes use existing lease transactions; reads validate persisted descriptors independently of current source ownership.

**Tech stack:** Swift, SQLite, Swift Testing.

**Spec:** [Approved design](2026-10-31-acp-v2-inbound-ledger-design.md).

## Global constraints

- Branch nacho/acp-v2-inbound-ledger; base cf9aa29df52bcf77e2f13ca98657aebe8c7c221f. Preserve unrelated Ghostty/research. No commits or PR until shipping requested.
- Production remains v1-only. No receiver/runner activation, replies/intents, resolution, permission/execution, UI, queue/lifecycle, upstream resume, SSH replication, helper changes or compaction.
- Never parse/re-encode retained frames or key by payload/method/wire request ID/helper pending ID. Stdio keys use capture receipt UUID; broker keys use source generation/event cursor.
- One globally unique source maps to one immutable local/upstream context. Broker ACK is excluded from identity; first baseline is fixed.
- All writes require matching current lease and source; no nested transaction under withLeaseFence. Successful receipt is returned after COMMIT and has internal initialization.
- Replay values contain no callbacks or durable-write proof. Retained pending metadata is historical, never a claim of current liveness or permission to answer.
- Defaults128 records/1MiB, max1000 records and Int32.max bytes. Oversized first record returns alone with explicit flag. Check lengths before loading BLOBs.

## Files and interfaces

- Create AlasSessions/ACP/Session/ACPV2InboundLedger.swift: immutable source, stream, record, receipt, continuation/page and typed error values.
- Create adjacent ACPSessionStore+V2InboundLedger.swift: schema, source/row validation, lease-fenced registration/retention.
- Create adjacent ACPSessionStore+V2InboundRecovery.swift: passive discovery, descriptor validation and length-first count/byte-bounded record pages.
- Modify ACPSessionStore.swift: migration32→33 before schema version publication; no replica triggers.
- Modify ACPSessionPersistence.swift: public actor methods forwarding registration/retention/discovery/pages.
- If needed, factor the existing header decoder into pure public ACPV2InboundDelivery.decodeHeader(from:) and delegate instance/record decode to it; do not reconstruct a transport delivery during recovery.
- Extend existing AlasTests/ACP/Session/{ACPSessionStoreCRUDTests,ACPSessionStoreTests,ACPSessionPersistenceTests}. Temporary SwiftPM copies changing only app import are permitted and removed before final checks.

Public methods on store/actor:
- registerV2InboundLedger(sessionId: String, upstreamSessionId: String, source: ACPV2InboundLedgerSource, fence: ACPSessionLeaseFence) throws -> ACPV2InboundLedgerStream
- retainV2Inbound(_ delivery: ACPV2InboundDelivery, to stream: ACPV2InboundLedgerStream, fence: ACPSessionLeaseFence) throws -> ACPV2InboundLedgerReceipt
- loadV2InboundLedgerStream(sessionId: String, beforeStreamID: UUID? = nil) throws -> ACPV2InboundLedgerStream?
- loadV2InboundLedgerPage(stream: ACPV2InboundLedgerStream, after: ACPV2InboundLedgerContinuation? = nil, maxRecords: Int = 128, maxBytes: Int = 1_048_576) throws -> ACPV2InboundLedgerPage

Stream contains id/local/upstream/source/formatVersion/initialBrokerCursor and raw-v2 context. Record contains streamID/positive Int64 ordinal/original receiptID/connectionID/common Source/exact frame. Receipt contains record/wasInserted, no callback. Continuation contains streamID/afterOrdinal. Page contains records/next/isAtEnd/hasKnownMissingPrefix/containsOversizedRecord. Errors distinguish invalidInput, staleLease, incompatibleStream, conflictingReceipt, unsupportedFormat and corruptRecord.

## Review focus

- A repeated broker event changes capture connection/origin, not its original bytes/pending metadata. Preserve first capture, reject nil/non-nil/different helper metadata conflicts. Task1.
- Helper or adapter IDs can be reused at later cursors; both receipts survive. Separate equal stdio captures survive; concurrent copies converge. Task1.
- Global source claims must conflict across local/upstream contexts, without rolling back unrelated history or allocating ordinals on SQL failure. Task1.
- Reopen after clear/replacement/lease succession must discover old streams without current authority. Stored requests never become current pending handles. Task2.
- Paging must not load unbounded BLOBs, stall on oversized-first, skip invalid metadata or accept a continuation from another stream/nonexistent ordinal. Task2.

## Task1: Atomic registration and exact receipt retention

- [x] Add failing CRUD regressions for registration/reopen/global source conflicts, stdio copy/equal captures, broker reattachment/ACK baseline/metadata conflicts and reused helper ID, invalid authority and real SQL rollback. Add schema32 migration preserving existing session/update/submission rows and proving ordinary v1 writes create no ledger rows. Add concurrent actor retry regression. Observe missing-contract RED.
- [x] Implement immutable values, additive schema33, strict canonical keys/ranges/UUID/source validation, registration and retention. Store raw bytes without header validation. Allocate ordinal under lease transaction, preserve original retries and validate DB descriptor each write. Add actor methods.
- [x] Run schema/CRUD/persistence selection through temporary source-identical import-adjusted SwiftPM suites. Inspect actual counts and record GREEN; no commit.

## Task2: Bounded passive discovery and recovery

- [x] Add failing count/byte/oversized/empty-evidence paging, continuation rejection, corrupt/unsupported row and lifecycle retention tests to existing suites. Include no-callback/no-ACK/no-replica mutations and session-delete cascade, discovery across source generations and lease succession. Observe missing-contract RED.
- [x] Implement discovery and snapshot paging: at most count+1 length rows, materialize only selected prefix; validate descriptor/position. Add actor methods. Recover original metadata without active transport values, receipts or liveness state. Pure header view may fail while bytes remain readable.
- [x] Run affected store/schema/persistence and common-delivery/owner/restore suites; inspect counts. Remove temporary app harnesses. No commit.

## Task3: Final checks, review and tracking

- [x] Final affected package checks, full SwiftFormat lint, tracked/new-file whitespace checks. Attempt native schema/CRUD/persistence once with existing caches; distinguish cache/infrastructure failure from tests, no unrelated dependency repair or full app plan.
- [x] One fresh whole-change review against fixed base, including untracked files and excluding unrelated inputs. Fix material findings in one RED/GREEN pass, ledger declined/deferred minors; no rereview.
- [x] Complete plan/ledger and update umbrella2213 with exact evidence and excluded response/liveness/runner scope. Keep work uncommitted until shipping requested.

## Preflight rulings

Approved scope already specifies inline execution and no second menu; proceed after writing this plan. Focused repository checks override generic full-suite guidance, and shipping authorization overrides generic per-task commit steps. Existing isolated worktree is retained. Task1 stream/record contracts feed Task2 recovery with no interface conflict. Passive parsing is a view only; no interpreted request state is persisted.

## Completion evidence

- Mutation contract RED/GREEN: missing APIs followed by97 tests/3 suites passing through source-identical temporary app suites with only the import adjusted.
- Recovery contract RED/GREEN: missing read APIs followed by105 tests/4 suites passing. Combined store/schema/persistence/common/owner/restore/negotiation selection passed140 tests/7 suites before final review.
- Pre-review Unicode regression failed2 definitions with3 issues; UTF-8 identity comparison fixed upstream and opaque pending identity. Embedded NUL evidence round-trips unchanged.
- One fresh whole-change review found3 Important findings: canonical-equivalent incoming broker IDs/canonical keys; corrupt current ACK defaulting to zero; invalid UTF-8 metadata repaired by the shared row decoder. One combined fix pass added failing regressions (3 definitions/13 issues), exact source checks/indexed redundant source lookup, raw typed descriptor validation and strict metadata UTF-8 validation. No shared session/SQLite decoder behavior changed.
- Validation of the text fix additionally reproduced Foundation stripping a leading UTF-8 BOM (2 definitions/3 issues). The standard-library validating decoder preserves BOM/NUL and rejects invalid bytes. Final affected combined run passed143 tests/7 suites, including all review regressions. All temporary app test copies were removed. No rereview or deferred findings.
- Final affected package selection passed149 tests/13 suites. Full SwiftFormat lint:0/2714 files require formatting,1 skipped. Tracked/new-file whitespace checks passed.
- Native schema/CRUD/persistence is inconclusive: missing cached dependency manifests stopped Xcode before compilation. The completed xcresult is unknown with0 total tests. No dependency repair, native pass, CI or live adapter/SSH result is claimed; repeating the unchanged infrastructure failure after the fixes was unnecessary.

Accepted review exclusions: production activation, receiver/reply execution and request liveness remain outside this passive slice; local check evidence is executor-owned; unrelated Ghostty/research inputs remain untouched. No current pending state or live transport handle is reconstructed from historical records.

Implementation choices retained: approved inline execution/focused checks without another menu; pure shared static header interpretation rather than recreating a receipt; exact UTF-8 identity rather than linguistic equivalence. Costs are limited to future consumers using the additive parser and preserving original ID encodings. The ledger and successful write receipts remain separate from consumption and reply authority.

Umbrella2213 records local implementation and the next request-owner/reconciliation/response-intent slice. Shipping was authorized after final verification; commit and PR publication follow the reviewed scope.
