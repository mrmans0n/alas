# ACP 2 submission ledger implementation plan

> **For agentic workers:** Use superpowers:executing-plans with the established native inline method, meaningful TDD per task and one fresh final review. Keep work uncommitted until shipping is requested.

**Goal:** Persist exact prompt-attempt correlation and raw RPC outcomes, with conservative passive recovery.

**Architecture:** Add immutable ledger values in AlasSessions, session-owned SQLite tables and actor forwarding. Registration and outcome mutations share existing lease-fenced transactions. Historical reads remain passive and bounded; there is no sender or new canonical owner.

**Tech stack:** Swift, SQLite, Swift Testing, existing AlasCore module boundaries.

**Spec:** [Approved design](2026-10-30-acp-v2-submission-ledger-design.md).

## Global constraints

- Branch nacho/acp-v2-submission-ledger; fixed base 077638c565dc859965d36368e0c3da999f382cc6. Preserve unrelated research and Ghostty checkout.
- Production remains v1-only. No dispatch, automatic retry, pending adapter-request recovery, queue/UI integration, SSH or helper changes.
- Store full original response BLOBs. Mutations require matching writer lease and current broker source, excluding mutable ACK from identity. Never nest transactions under withLeaseFence.
- Registration without outcome recovers uncertain. Valid RPC errors do not establish rejection or completion. One immutable outcome per attempt; explicit retries require distinct registrations.
- Stdio binding uses real reserved signed/string wire ID plus connection; broker binding uses ID/generation/operation key and pins helper request ID from the first response.
- Paging defaults 128 records/1MiB, maximum 1000/Int32.max bytes; one oversized first record makes progress explicitly.

## Files and contracts

Create `Packages/AlasCore/Sources/AlasSessions/ACP/Session/ACPV2SubmissionLedger.swift` for immutable source, binding, registration, outcome, record, receipt, continuation, page and typed error values. Constructors for persisted values/receipts stay internal.

Create adjacent `ACPSessionStore+V2SubmissionLedger.swift` for schema, registration, exact outcomes and strict metadata validation. Add paging there unless size warrants an adjacent read extension.

Modify `ACPSessionStore.swift` for migration32 and `ACPSessionPersistence.swift` for matching actor entry points. Extend existing app store schema/CRUD and persistence suites; temporary source-identical import-adjusted SwiftPM harnesses are permitted and removed before native checks.

Interfaces:
- `ACPV2SubmissionSource`: stdio(connectionID) or broker(id,generation).
- `ACPV2SubmissionBinding`: stdio(connectionID,requestID:JSONRPCID) or broker(id,generation,operationKey), with source identity.
- `registerV2Submission(id:UUID, sessionId:String, upstreamSessionId:String, localRowID:UUID, binding:ACPV2SubmissionBinding, fence:ACPSessionLeaseFence) throws -> ACPV2SubmissionRegistration`.
- Registration contains id/session/upstream/localRow/binding and positive Int sequence, allocated monotonically per local session.
- `retainV2SubmissionOutcome(_ delivery:ACPRawRPCDelivery, for registration:ACPV2SubmissionRegistration, fence:ACPSessionLeaseFence) throws -> ACPV2SubmissionReceipt`.
- Outcome retains exact frame, original receipt/connection/source/provenance and interpretation accepted(ACPV2PromptAccepted), rpcFailure or uninterpretable. Receipt contains committed record and wasInserted, no callback.
- `loadV2Submission(id:UUID) throws -> ACPV2SubmissionRecord?`.
- `loadV2SubmissionPage(sessionId:String, upstreamSessionId:String, source:ACPV2SubmissionSource, after:ACPV2SubmissionContinuation? = nil, maxRecords:Int = 128, maxBytes:Int = 1_048_576) throws -> ACPV2SubmissionPage`.
- Continuation includes full filter and positive afterSequence; page contains records/next/isAtEnd/containsOversizedRecord. Registration-only record recovery is uncertain.

## Review focus

- Same wire ID under another stdio connection or another broker generation must remain distinct; wrong source cannot overwrite an attempt. Task1/2.
- ACK changes and a new broker attachment can retry the same event without replacing original provenance or consuming any handle. Task2.
- Source-bound malformed response or contradictory frame ID must retain uninterpretable evidence, never acceptance. Task2.
- Trigger-induced failure and concurrent copied receipts must not return partial/duplicate durable outcomes. Task2.
- Replay may correlate accepted rows in either echo order, but cannot invent foreground completion or a live callback. Task3.

## Task1: Immutable registration and additive schema

- [x] Extend existing store schema/CRUD tests with registration reopen/idempotency, source-scoped uniqueness, distinct local-row attempts, invalid source/range/session and stale-lease cases. Migration31→32 preserves sessions/update journal and ordinary v1 operations create no ledger rows. Observe missing-contract RED.
- [x] Implement source/binding/registration/error contracts and schema32. Use canonical structured source/binding keys, not delimiter concatenation for arbitrary string IDs/keys. Allocate positive sequence inside the lease transaction and reject Int exhaustion. Exact registration retries preserve original sequence; collisions fail without mutation.
- [x] Run selected schema/CRUD suites, verify actual count and record GREEN. No commit.

## Task2: Atomic exact outcome retention

- [x] Add regressions for reversed responses, exact accepted/error/malformed bytes across reopen, signed/string stdio and UInt64.max broker IDs, broker reattachment/ACK changes, duplicate copies and conflicting outcomes, binding mismatch and descriptor replacement. Add real trigger rollback and concurrent actor-retry evidence. Observe missing outcome contract RED.
- [x] Implement outcome/record/receipt values and fenced retention plus direct passive load. Store typed metadata losslessly and a bounded interpretation; on read validate metadata, binding and derived interpretation against original bytes. A bound malformed frame commits uninterpretable; cache/diagnostic/wrong source rejects without mutation. Different event identity or bytes conflicts even if payloads otherwise match.
- [x] Verify zero consumption on all storage paths and no ACK/session changes. Run affected suites, record GREEN. No commit.

## Task3: Bounded passive recovery and lifecycle

- [x] Add failing page count/byte/oversized/empty/foreign-continuation cases, corrupted metadata/format cases, historical source retention and session cascade. Reconstruct existing canonical session state from loaded registrations/acceptance plus snapshot echo in both orders, with no foreground completion. Observe paging RED.
- [x] Implement length-first bounded paging under a short read snapshot, registration-only records at zero frame bytes, full-filter continuations, and passive historical reads independent of current lease/descriptor. Keep ordinal order local and explicit.
- [x] Run affected package suites and focused native schema/CRUD/persistence suites where feasible. Report actual counts and infrastructure blockers. No unrelated dependency repairs.

## Task4: Final review and tracking

- [x] Remove temporary harnesses. Run affected package selection, full SwiftFormat lint and tracked/new-file whitespace checks; inspect every result.
- [x] One fresh review of the whole change against fixed base, including untracked files and excluding unrelated research. Fix material findings once with RED/GREEN, defer minors explicitly, no rereview.
- [x] Update umbrella2213 with merged2265 and local ledger evidence/remaining scope. Complete plan and ledger. No commit, push or PR until shipping requested.

## Preflight and rulings

Task1 registration/binding feeds Task2 retention; Task2 strict records feed Task3 pages. Shared signatures above agree. Domain values stay in AlasSessions to keep durable receipt construction internal. Native build inputs remain unchanged. The approved design already selects inline implementation; no repeat execution menu is needed.

## Verification evidence

- Registration RED confirmed missing API; GREEN: 66 tests/2 suites.
- Outcome RED confirmed missing retention/receipt contract; GREEN: 85 tests/3 suites.
- Paging RED confirmed missing bounded recovery. A subsequent 90-test run reproduced one cross-local-session binding collision; global binding uniqueness fixed it.
- Combined final selection passed 121 tests/7 suites, including 90 store/schema/persistence tests via temporary source-identical app suites with only import adjusted. All temporary files removed afterward.
- Final package-only selection passed 76 tests/7 suites. Full SwiftFormat lint reported 0/2698 files requiring formatting, 1 skipped. Tracked and new-file whitespace checks passed.
- Native schema/CRUD/persistence validation is inconclusive. Xcode failed package resolution on missing cached manifests before compilation. The result summary is unknown with 0 total tests. No dependency repair, native pass, CI or live adapter claim is made.

Logs are under /private/tmp/alas-ledger-*.log; native summary is /private/tmp/alas-ledger-app-summary.json.

## Final review and handoff

One fresh whole-change review found no Critical, Important or Minor findings. No corrective patch or rereview was needed. Transport identity reservation/handoff, canonical owner integration, queue/UI/retry behavior, stdio liveness and live v2 activation remain explicitly deferred. Native validation remains unverified for the dependency-cache reason above. Umbrella2213 now records merged2265 and the locally implemented ledger evidence. Shipping was requested after verification. The related changes are prepared for commit and PR; unrelated research and Ghostty inputs remain excluded.
