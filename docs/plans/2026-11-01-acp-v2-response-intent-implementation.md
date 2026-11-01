# ACP 2 durable response intent implementation plan

> Use superpowers:executing-plans for approved inline TDD. One fresh final whole-change review, one material fix pass if needed, no rereview or commits until shipping is requested.

**Goal:** Retain immutable chosen replies, explicit attempts and source-validated observations without creating current reply authority.

**Architecture:** Schema34 references schema33 inbound records. AlasSessions owns strict lease-fenced mutations and bounded passive recovery; ACPSessionPersistence forwards them. Existing transport results validate identity, while stored facts contain the normalized status plus immutable parent attribution, never reconstructed transport handles.

**Tech stack:** Swift, SQLite, Swift Testing.

**Spec:** [Approved design](2026-11-01-acp-v2-response-intent-design.md).

## Global constraints

Base c9e04e0d7f2155f92fb73118bdc0e265c0bd03a0, branch nacho/acp-v2-response-intent. Preserve Ghostty/research. No transport calls, active response/liveness owner, ACK, execution, UI, runner or production eligibility changes. Production remains v1-only. Existing opaque-object and signed-zero qualification limits remain.

## Files and interfaces

Create `Packages/AlasCore/Sources/AlasSessions/ACP/Session/ACPV2ResponseLedger.swift` for public intent/attempt/observation/receipt/page contracts and exact identity helpers. Create `ACPSessionStore+V2ResponseLedger.swift` for schema and intent/attempt registration, `ACPSessionStore+V2ResponseObservations.swift` for validation and append-only facts, and `ACPSessionStore+V2ResponseRecovery.swift` for bounded passive reads/strict decoders. Modify existing store migration, persistence forwarding and inbound helpers only to reuse internal current-source validation.

- `ACPV2ResponseIntent`: id, stream, request record, exact response frame.
- `ACPV2ResponseAttempt`: id, intentID, sequence:Int64, operationKey:ACPV2ReplyOperationKey.
- `ACPV2ResponseAttemptRecord`: attempt plus recovery (`uncertain`, `written`, `notWritten`).
- `ACPV2ResponseEvidence`: `.stdio(ACPV2StdioReplyResult)`, `.broker(ACPBrokerRawReplyResult)`, `.uncertain(message:String)`.
- `ACPV2ResponseFact`: persisted normalized `.stdio(status)`, `.broker(status)`, `.uncertain(message)`. All result identity is validated against immutable parents before insertion; no transport result/receipt is reconstructed on reads.
- `ACPV2ResponseObservation`: id, attemptID, sequence, fact.
- `ACPV2ResponseLedgerReceipt<Value>`: value, wasInserted; constructed after COMMIT only.
- `ACPV2ResponseLedgerContinuation`: kind (`intents`, `attempts`, `observations`), parentID, afterSequence. `ACPV2ResponseLedgerPage<Value>` contains records, next, isAtEnd, containsOversizedRecord. No nested histories.
- Errors: invalidInput, staleLease, incompatibleSource, conflict, unsupportedFormat, corruptRecord, sequenceExhausted.

Store/actor methods:

- `registerV2ResponseIntent(id:UUID, request:ACPV2InboundLedgerRecord, in:ACPV2InboundLedgerStream, frame:Data, fence:ACPSessionLeaseFence) -> Receipt<Intent>`.
- `registerV2ResponseAttempt(id:UUID, for:Intent, operationKey:Key, fence:Fence) -> Receipt<Attempt>`.
- `retainV2ResponseObservation(id:UUID, for:Attempt, evidence:Evidence, fence:Fence) -> Receipt<Observation>`.
- `loadV2ResponseIntent(id:UUID) -> Intent?`, `loadV2ResponseAttempt(id:UUID) -> AttemptRecord?`.
- `loadV2ResponseIntentPage(stream:Stream, after:Continuation?=nil, maxRecords:Int=128, maxBytes:Int=1048576) -> Page<Intent>`.
- `loadV2ResponseAttemptPage(intentID:UUID, after:Continuation?=nil, maxRecords:Int=128, maxBytes:Int=1048576) -> Page<AttemptRecord>`.
- `loadV2ResponseObservationPage(attemptID:UUID, after:Continuation?=nil, maxRecords:Int=128, maxBytes:Int=1048576) -> Page<Observation>`.

All store methods throw; actor methods are callable asynchronously. Intent sequence for paging is its inbound ordinal. Attempt and observation sequences are parent-local positive integers. Opaque keys and diagnostics use strict UTF-8 BLOBs, preserving BOM/NUL and avoiding SQLite's repairing String projection. Namespace derives from the validated stream. Request bytes remain in the inbound ledger; response bytes are stored once.

## Review focus

- Crash after attempt registration without a saved terminal fact remains uncertain. Task2/3.
- Unicode-equivalent keys, pending IDs and parent attribution never alias. Task1/2/3.
- Stale queued/uncertain observations cannot erase terminal certainty or permit another key. Task2.
- Generation/lease/context loss and SQL aborts cannot return a successful commit receipt or mutate ACKs. Task1/2.
- Historical reads validate metadata but require no active lease/descriptor; pages bound payload loading including oversized records. Task3.

## Task1: Immutable intent and attempt registration

- [x] Extend existing CRUD/schema/persistence suites with failing contracts: `responseIntentsKeepOneExactDecisionPerRetainedOrigin`, `responseIntentRejectsNonRequestOrMismatchedEvidence`, `responseRegistrationAuthorityAndRollbackAreAtomic`, `responseMigrationPreservesExistingJournals`. Parameterize source and failure cases. Assert exact frames, idempotence on reopen, conflicts for changed UUID/frame, distinct reused origins, unchanged ACK/consumption and empty new tables after migration. Observe missing-API RED.
- [x] Implement schema34, exact parent lookup/validation and intent registration. Reuse common header/response parsing; compare ID identity exactly. Mutations validate raw lease identities and current source inside withLeaseFence. Store strict key/diagnostic BLOBs; no callback invocation.
- [x] Implement explicit attempt registration and namespace uniqueness. Repeated UUID/parent/key is idempotent; changed reuse conflicts. First registration succeeds, second unresolved key conflicts. Later Task2 supplies factual not-written gate; initial registration must not allow replacement on missing evidence.
- [x] Add actor forwards and run `ACPSessionStoreCRUDTests|ACPSessionStoreSchemaTests|ACPSessionPersistenceTests` using temporary exact app source imports where native is unavailable. Confirm nonzero suite counts and GREEN. No commit.

## Task2: Source-bound observation facts and certainty

- [x] Add failing cases `responseFactsRefineUncertaintyWithoutRegressingTerminalEvidence` and `responseObservationIdentityAndContradictionCannotMutateHistory`: stdio queued/in-flight/cancel uncertainty/late written, not-written explicit new-key path, broker rejection/uncertainty blocking rekey, changed identities/keys/origins, same observation UUID reuse, injected abort. Use test-only AlasACP import to construct typed result evidence without widening product APIs. Observe missing observation API RED.
- [x] Implement append-only observation validation. Keep result source identities in immutable parents and store validated status kind; local diagnostic uncertainty never becomes terminal proof. Contradictory written/not-written facts conflict; stale snapshots remain evidence without regressing recovery. Typed not-written can permit an explicit next attempt; never use last-row status as certainty.
- [x] Compute recovery with bounded scalar SQL summaries rather than loading whole observation histories. Validate structural kinds/statuses/versions and contradictory facts; decode detailed diagnostic bytes on observation reads. No materialized certainty cache that can drift.
- [x] Add concurrent actor idempotence/fence regression for intent/attempt/observation registration. Run affected store/persistence suites and inspect GREEN counts. No commit.

## Task3: Bounded passive recovery and strict metadata

- [x] Add missing-API RED for `responseRecoveryPagesKeepContextsAndOversizedPayloads`, plus strict corruption/identity variants. Assert context-bound continuation kinds, byte/count boundaries, reopened uncertain attempts, terminal facts across stale snapshots, changed current broker generation/lease still allowing passive history, and invalid UTF-8/SQL types/format metadata throwing.
- [x] Implement strict decoders and length-first snapshot paging. Verify parent existence and continuation row; maxRecords1...1000, maxBytes1...Int32.max. Account for response/request payload, keys and diagnostic bytes; one oversized record alone advances. No unbounded nested observation or attempt arrays.
- [x] Forward all passive actor APIs. Extend schema regression to preserve populated prior journals when creating empty response tables; change schema assertions that incorrectly pin33 to targetSchemaVersion.
- [x] Run affected package suites first, attempt native focused store suites with isolated DerivedData, record missing-cache failure as inconclusive. Remove temporary copies, verify repository-state package suites, full SwiftFormat lint and whitespace checks. No commit.

## Task4: Final review and handoff

- [x] Dispatch one fresh read-only whole-change review against fixed base including new files, excluding unrelated inputs and temporary copies. Judge by actual consequences. Critical/Important findings receive one combined RED/GREEN fix pass; deferred Minors and all declined judgments are recorded. No rereview.
- [x] Update plan/ledger/umbrella evidence, report verified counts and limits. Leave uncommitted until shipping is requested.

## Preflight rulings

The approved design already specifies inline execution, so its approval authorizes plan and execution without another menu. Exact app-source harnesses supplement native validation only. Retained observation facts are normalized after identity validation and inherit immutable parent binding; they do not fabricate transport handles. Intent pages carry one origin/response, attempt pages one recovery summary, observation pages one fact, keeping history bounded. A not-written result permits another attempt only while it is the latest registered attempt's factual terminal outcome. This stores retry eligibility history, not current request authority.

## Execution rulings and preliminary evidence

- Registrations and typed observation mutations passed143 tests in7 affected suites with exact app source import-only copies; those copies were removed before final review.
- A retained32-byte SHA256 digest binds exact intent identity, source/stream attribution, original request and chosen response bytes. A failing regression showed that foreign keys alone could reload changed-but-valid parent evidence as the original choice. The digest checks binding consistency and grants no authorization; cost is hashing on reads and32 bytes per intent.
- Paging conservatively counts parent validation payload per child and caches it only within the read snapshot. This trades page density for a bounded payload budget and explicit oversized-record progress.
- Test-only AlasACP import constructs typed stdio facts without expanding product constructors. No transport calls or reconstructed reply handles were added.

## Final review fix pass

One fresh final review found3 Important findings and no Critical/Minor findings. The combined regression run failed2 definitions/1 suite with8 issues: NUL-suffixed observation UUIDs opened rekey, and empty child histories hid invalid parent bindings/metadata. Fixed in one pass, no rereview.

New local `ACPSessionStore+V2ResponseValidation.swift` preflights SQLite storage types and byte lengths before payload materialization, with exact32-byte digests and36-byte UUID fields, bounded source metadata and explicit known-column projections. Scalar recovery checks UUID BLOB byte length as well as text shape. Parent validation runs even when no child is selected. The page oversized marker includes an oversized parent validation record even for an empty child history; this preserves strict validation without hiding its memory cost. Fixed-width lookahead IDs are length-checked without selecting unbounded malformed values.

Accepted declined judgments: current liveness/response ownership/transport execution/authorization/ACK/production integration remain excluded; parser/signed-zero limitations remain qualification work; detailed diagnostic reads validate UTF-8 while scalar recovery deliberately avoids loading bodies; digest consistency does not authenticate coordinated malicious DB rewriting; unrelated inputs excluded; native/CI/live evidence remains unavailable.

## Final verification and handoff

- 145 tests/7 affected suites passed after the combined review fix, with exact app store/schema/persistence test sources imported through AlasCore; temporary copies were removed. Log `/private/tmp/alas-response-review-verified.log`.
- 107 tests/11 package suites passed on the final repository state without temporary copies. Log `/private/tmp/alas-response-package-complete.log`.
- Full SwiftFormat lint passed,0/2747 files requiring formatting,1 skipped. Tracked and new-file whitespace checks passed. Log `/private/tmp/alas-response-lint-complete.log`.
- Native focused CRUD/schema/persistence validation stopped before compilation on missing cached dependency manifests and manifest-cache access. Inconclusive; no native, CI or live adapter/SSH pass is claimed. Log `/private/tmp/alas-response-native.log`.

One final review and one material fix pass are complete. No new Minor findings were deferred and no rereview occurred. Existing shared parser/signed-zero limitations remain deferred qualification work. Scalar summaries intentionally do not validate diagnostic UTF-8 bodies until detailed reads; they cannot use those bodies as terminal write evidence. No response/liveness owner, semantic execution, ACK, UI or production integration was introduced. The digest is a consistency check, not protection against coordinated malicious database rewriting.

Work remains uncommitted as requested, with unrelated Ghostty/research preserved. Next: attachment/current-request reconciliation and a response owner that composes durable registration with exact transport handoff and outcome retention.
