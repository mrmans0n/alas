# ACP v2 fresh-session runner implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Preserve the previously chosen inline execution method, with one fresh final reviewer and one combined material fix pass, without rereview. Do not start implementation until the user confirms this plan.

**Goal:** Provide an opt-in package runner for a fresh stdio ACP v2 session, preserving update/request order, exact response authority and explicit ownership withdrawal.

**Architecture:** Claim one ordered method intake before starting the client. Factor the existing durable owners into awaitable preparation and per-delivery operations, then compose them with bootstrap, projection and the existing decision coordinator. Apply permission subjects through the canonical owner before offering decisions, while asynchronous inspection and replies remain independent of intake.

**Tech stack:** Swift, Swift Testing, AlasACP, AlasSessions, AlasCore, existing SQLite journals and JSONRPCFrameWriting transport seam. No new dependency or app target changes.

**Spec:** `docs/plans/2026-11-04-acp-v2-session-runner-design.md`, approved on 2026-11-04.

**Execution:** Completed inline on `nacho/acp-v2-session-runner`. The affected selection passed 222 tests across 18 suites; SwiftFormat lint and whitespace checks passed. One fresh final review found no actionable issues. The user subsequently authorized committing the related changes and opening a PR. Detailed execution evidence is in this plan's ignored SDD ledger.

## Global constraints

- Fresh stdio first. Production remains v1. No production manager installation, new views, browser opening, client tool execution, remembered approvals, queue advancement, outgoing session/cancel or session/close, broker installation, resume/adoption, SSH or live adapter qualification.
- Use Alas identity. Preserve exact raw bytes, connection/receipt identity and original response handles. Do not use v1 reducers or AnyCodable/Double conversions.
- One intake mode per client, selected before start. No merge of independently read streams and no second consumer of bootstrap's runtime observations.
- Existing update/inbound/submission/response owners retain COMMIT, consumption and physical-write authority. No fabricated wire updates or duplicate journal records for permission subjects.
- Stop and explicit ownership invalidation must settle local waiters without releasing blocked I/O. `isCurrent` is a defensive check, not an ownership subscription.
- Elicitation is disabled by default. Enable only modes with an explicit handler, using the same typed configuration for advertisement and interpretation.
- Prompt acceptance, request answers, URL completion and observation loss never synthesize foreground success.
- Follow repository testing policy: extend existing suites; use events/gates instead of fixed sleeps; no default serialization; assert nonzero test counts. CI owns the full configured test plan.
- Preserve unrelated `ThirdParty/ghostty` and `docs/research/2026-10-25-acp-v2-adapter-support.md`. Leave #2213 unchanged. Do not create a PR or publish until requested.
- Preserve the prior no-interim-feature-commits preference. Record per-task verification in the execution ledger; make the final related commit when requested. No agent attribution.

## Review focus

1. EOF during setup versus EOF after buffered live frames: Task 1 preserves FIFO termination, Task 5 distinguishes setup failure from observation loss without fabricated success.
2. A late eligibility check offers B after real update C: Task 3 applies the subject once at retention, never again at offer time.
3. A reentrant observer submits, stops or installs a successor during optimistic-row registration: Tasks 4 and 5 reserve the operation first and recheck authority after every callback.
4. A permission answer is physically written while observation persistence is held and its ID is reused: Tasks 2 and 4 keep intake independent and inspect the exact current transport origin.
5. Cancellation before a blocked operation's worker is installed, or stale completion after a successor exists: Task 5 pins cancellation synchronously and settles each waiter once without touching the successor.

## Files and responsibilities

Paths below are relative to `Packages/AlasCore/` unless stated otherwise.

- Create `Sources/AlasACP/ACP/Protocol/ACPV2OrderedIntake.swift`: transport-order event enum and one claimed intake, with no persistence or canonical authority.
- Modify `Sources/AlasACP/ACP/Protocol/ACPStdioClient.swift`: exclusive routing mode, claim/start guard, ordered yield/termination, original reply-capture registration.
- Modify `Sources/AlasSessions/ACP/Session/ACPV2SessionUpdateOwner.swift` and `ACPV2InboundReceiptOwner.swift`: common prepare/process/EOF implementations used by both the old stream loops and ordered runtime.
- Modify `Sources/AlasSessions/ACP/Session/ACPV2AttachmentRuntime.swift`: ordered fresh startup and one serial intake worker; retain existing split mode and broker behavior.
- Modify `Sources/AlasACP/ACP/Protocol/ACPV2InteractiveRequest.swift`, `Sources/AlasACP/ACP/Session/ACPV2ActivityState.swift`, `ACPV2SessionState.swift`: typed permission-tool patch and shared canonical reduction.
- Modify `Sources/AlasSessions/ACP/Session/ACPV2SessionProjection.swift`: project the dedicated subject publication through existing row logic.
- Modify `Sources/AlasSessions/ACP/Session/ACPV2SessionBootstrap.swift`: typed capabilities, ordered attachment, and bound installation context available before runtime starts.
- Create `Sources/AlasSessions/ACP/Session/ACPV2SessionRunner.swift`: lifecycle, component composition, typed callbacks, managed public operations and invalidation.
- Extend the existing negotiation, inbound-delivery, update/inbound-owner, state, projection, bootstrap, runtime and decision suites. Create only `Tests/AlasCoreTests/ACPV2SessionRunnerTests.swift` for the new runner.

## Execution preparation

- [ ] Read the spec and relevant AGENTS.md. Confirm cwd and preserve unrelated changes. This worktree is already isolated, but its branch belongs to merged PR #2343: at implementation time create a fresh branch such as `nacho/acp-v2-session-runner`, without rewriting published history. Fetch/integrate current main and record the actual base before editing product code. Do not assume the name is available or silently reuse someone else's branch.
- [ ] Create `.superpowers/sdd/2026-11-04-acp-v2-session-runner-implementation/progress.md` with base, task progress, RED/GREEN logs, interface rulings and unresolved limits.
- [ ] Run an affected baseline with `rtk swift test --package-path Packages/AlasCore --filter 'ACPV2SessionBootstrapTests|ACPV2AttachmentRuntimeTests|ACPV2SessionProjectionTests|ACPV2RequestDecisionCoordinatorTests'`. Use the existing isolated scratch/cache configuration if needed. Read the actual `Test run with N tests in M suites` line. Stop to classify any baseline failure rather than attributing it to this work.

## Task 1: Capture methods in transport order

**Files:** New `ACPV2OrderedIntake.swift`; modify `ACPStdioClient.swift`; extend `ACPV2InboundDeliveryTests.swift`.

**Interfaces:**

```swift
public enum ACPV2OrderedIntakeEvent: Sendable {
    case update(ACPV2SessionUpdateDelivery)
    case inbound(ACPV2InboundDelivery)
    case diagnostic(ACPRawRPCDelivery)
}
public final class ACPV2OrderedIntake: Sendable {
    public let connectionID: UUID
    public let events: AsyncStream<ACPV2OrderedIntakeEvent>
    // Creation is restricted to ACPStdioClient; identity is not reconstructible.
}
// ACPStdioClient, MainActor:
public func claimV2OrderedIntake() throws -> ACPV2OrderedIntake
```

The token is single-attachment input, not reply authority. The facade retains its identity and validates it when constructing an ordered runtime attachment. Claim failure is local and consumes no traffic. Add an explicit client started flag under its existing lock; reject claim after start, drain or another claim. Ordered mode finishes unused split streams and emits no copies to them. Default split mode remains unchanged. Standalone split-mode attachment/bootstrap claim paths must reject an ordered-selected client unless the matching intake token is supplied.

- [ ] Add parameterized `selectedOrderedIntakeKeepsMethodOrderAndOriginalReceipts` using an in-memory frame-writing transport: update A, permission B, malformed diagnostic, cancellation, update C. Assert exact case/byte order, matching connection IDs, one consumption per copied delivery, and B can be answered through its original stdio capture. No split stream yields a duplicate.
- [ ] Add `orderedClaimRequiresAnUnusedClient` for started, already claimed, stopped and v1 clients. Assert rejection without reads/writes. Include a response frame interleaved with method frames: its send continuation must complete while ordered intake is not drained. Include EOF: buffered events arrive before stream termination.
- [ ] Run `rtk swift test --package-path Packages/AlasCore --filter ACPV2InboundDeliveryTests`; record RED from missing contract or incorrect behavior.
- [ ] Implement the interfaces and route under the existing serialized frame-dispatch boundary. Share receipt construction and reply registration, not reconstructed copies. Keep RPC response resolution outside the method FIFO. Finish the ordered stream wherever facade method streams terminate.
- [ ] Rerun `ACPV2InboundDeliveryTests|ACPV2SessionUpdateDeliveryTests|ACPRawRPCDeliveryTests|ACPRawReplyTests` and record nonzero GREEN. Record the deliverable in the ledger instead of an interim commit.

## Task 2: Drive existing owners one capture at a time

**Files:** Update/inbound owners, attachment runtime, bootstrap attachment constructor; existing owner/runtime tests.

**Interfaces:** Add these internal MainActor methods to their existing owner types:

```swift
func prepareFreshOrdered() async throws
func processOrdered(_ delivery: ACPV2SessionUpdateDelivery) async throws // update owner
func processOrdered(_ delivery: ACPV2InboundDelivery) async throws // inbound owner
func finishOrderedInput() throws
```

`prepareFreshOrdered` registers and validates its journal using the existing fenced operations. Update preparation also verifies the submission page is empty. It rejects any historical record or missing-prefix evidence before applying history. Split-mode prepare continues existing restoration. Both modes use the same private processing operations and error transitions. One owner cannot start both modes, overlap two deliveries or process before preparation.

Add `Attachment.init(stdioClient: ACPStdioClient, orderedIntake: ACPV2OrderedIntake) throws` to runtime and bootstrap attachments. Validate matching client/token identity. Add `runtime.startFreshOrdered() async throws` for this mode only. It prepares both owners, establishes the fresh default after preparation but before intake, starts the sole serial worker and exposes ready. Refactor the default's guard to permit exactly this prepared-but-undrained phase; never permit a second default or an overwrite after live application. Legacy `start()` retains its semantics and rejects ordered attachments. Bootstrap's ordered path calls this method instead of its current default-plus-start sequence.

- [ ] Extend `ACPV2AttachmentRuntimeTests` with `orderedRuntimeWaitsForEachCommitBeforeTheNextCapture`, parameterized by held update append or inbound retention. Assert no later retention/application/consumption before release; after release verify canonical order and original receipt consumption. Block inspection separately and prove intake still advances.
- [ ] Extend owner tests with `orderedPreparationRejectsHistoricalState`, covering nonempty update, submission and inbound streams and known missing prefix. Assert no replay, default publication, capture consumption or dispatch. Retain existing standalone replay tests unchanged.
- [ ] Run the named owner/runtime suites to record RED.
- [ ] Factor the common processing implementations, then add ordered runtime startup/loop. Synchronous callback failure propagates to runtime withdrawal before the next event. Diagnostics are adapted using the existing diagnostic path and never registered as reply captures. EOF after buffered events calls the owners' natural observation-loss path; stop uses intentional withdrawal instead.
- [ ] Run `ACPV2SessionUpdateOwnerTests|ACPV2InboundReceiptOwnerTests|ACPV2AttachmentRuntimeTests|ACPBrokerRawClientTests`; record GREEN and inspect the standalone broker coverage count. Do not change broker ordering or recovery in this task.

## Task 3: Apply committed permission subjects canonically

**Files:** Interactive request, activity/state reducers, update owner, runtime, projection; existing interactive/state/projection/runtime tests.

**Interfaces:**

```swift
// ACPV2InteractiveRequest.Permission.Subject, validated during decode:
public let toolCallUpdate: ACPV2SessionUpdateEnvelope.ToolCallUpdate?
// ACPV2ActivityState:
public mutating func applyToolCall(_ patch: ACPV2SessionUpdateEnvelope.ToolCallUpdate,
    context: Context) -> [Effect]
// ACPV2SessionState:
public mutating func applyPermissionToolCall(_ patch: ACPV2SessionUpdateEnvelope.ToolCallUpdate,
    context: Context) -> [Effect]
// Update owner, internal; validates current stream/connection and deduplicates origin:
func applyPermissionSubject(_ request: ACPV2InteractiveRequest,
    origin: ACPV2InboundLedgerRecord) throws
// CanonicalPublication.Change:
case permissionSubject(origin: ACPV2InboundLedgerRecord, effects: [ACPV2SessionState.Effect])
```

Factor normal tool-call updates and subjects through the same activity patch operation. `ACPV2SessionState` maintains canonical row order from new activity keys. Subject publication increments canonical revision but never update journal ordinal, latest state observation or foreground generation. Runtime applies it only in ordered mode, from the committed original validated session permission, before coordinator receive. Deduplicate by stream and original origin, not JSON-RPC ID. The old standalone mode keeps its existing contract and gains no cross-stream order claim.

- [ ] Extend `ACPV2SessionStateTests` with `permissionToolSubjectsShareToolPatchSemanticsWithoutChangingForeground`: pin omitted/clear/value fields, a newly created tool's stable order, and unchanged lifecycle evidence. Extend existing interactive tests to pin validated patch extraction while preserving raw subject metadata.
- [ ] Add runtime regression `permissionSubjectPrecedesOfferAndIsNeverReappliedAfterLaterUpdate`, parameterized by delayed inspection and update/inbound COMMIT. Emit title A, subject title B, update title C. Capture canonical title sequence A/B/C, assert projection contains B before an offer is possible, and assert delayed offer leaves C intact. A subject cannot append a fake update journal record or advance its ordinal. Repeat the same original origin and assert no duplicate subject publication.
- [ ] Pin malformed, command, future and wrong-session subjects using the existing parameterized classification coverage: no canonical tool mutation or new reply authority. A reentrant stop in subject projection prevents offer and consumption.
- [ ] Record RED, implement the interfaces plus projection switch handling, then run `ACPV2InteractiveRequestTests|ACPV2ActivityStateTests|ACPV2SessionStateTests|ACPV2SessionProjectionTests|ACPV2AttachmentRuntimeTests`. Record GREEN and the preserved update/canonical revision distinction.

## Task 4: Compose the fresh runner and supported interactions

**Files:** New runner and runner tests; bootstrap and negotiation/bootstrap tests; small runtime accessor/context changes if needed.

**Interfaces:** New MainActor runner with these public operations:

```swift
public init(session: ACPSession, client: ACPStdioClient,
    persistence: ACPSessionPersistence, fence: ACPSessionLeaseFence,
    info: ACPImplementationInfo, interactions: InteractionHandlers = .init(),
    journals: ACPV2AttachmentRuntime.Journals? = nil,
    isCurrent: @escaping @MainActor () -> Bool,
    onEvent: @escaping @MainActor (Event) -> Void) throws
public func start(params: ACPV2SessionNewParams,
    deadline: ContinuousClock.Instant) async throws -> ACPV2SessionNewResult
public func submit(id: UUID, row: ACPMessage,
    params: ACPSessionPromptParams) async throws -> ACPV2SubmissionRecord
public func decide(_ handle: ACPV2RequestDecisionCoordinator.Handle,
    decision: ACPV2InteractiveRequest.Decision) async throws -> ACPV2ResponseOwner.Receipt
public func stop()
public func invalidateOwnership()
```

`InteractionHandlers` is a public nested MainActor struct with optional `form` and `url` callbacks taking the coordinator's original Handle and an injectable `ACPV2InteractiveRequest.FormValidator`, defaulting to the existing validator. Nil handler disables that mode. All coordinator events, including permission offers and form/URL offers, also reach `onEvent(.interaction(event))` as observations; only the corresponding typed handler controls mode advertisement. `Event` also includes reliable `.completion(ACPSessionLifecycle.ForegroundCompletion)`. Define public `Status` with idle, starting, ready, replacementRequired, observationLost, stopped, ownershipLost and failed states, a current status property and latest-only observations. Correctable `Failure` cases include notReady, busy, invalidInput and invalidated.

The runner owns no process lifecycle beyond calling the supplied client's one-shot `start()` after successful claims. Construction claims ordered intake/bootstrap exclusivity before any external callback or start; failure releases its own claims without consuming buffered traffic. Make early invalid-destination checks before client start, and rely on projection reservation for final exclusivity. The supplied session must be an empty eligible destination; optimistic rows enter only through submit. No existing transcript adoption.

Add bootstrap `InstallationContext` with `result: ACPV2SessionNewResult`, `binding: ACPV2FreshSessionBinding`, `runtime: ACPV2AttachmentRuntime` and `connectionID: UUID`. Add optional throwing `onInstalling(InstallationContext)` invoked before runtime startup. Preserve existing `onRuntimeCreated` users; run both hooks under current checks and document their order. The runner uses only onInstalling, since the existing runtime-only hook cannot reveal the freshly bound upstream ID. Projection and coordinator are installed there, before the default or buffered methods can publish.

Add bootstrap's typed optional `interactionSupport: ACPV2InteractiveRequest.Support = .init()` input. Validate `form || url` implies `elicitation` before initialize. The runner derives it entirely from its handlers, and passes the same value to the coordinator. Generate only `capabilities.elicitation.form = {}` and/or `.url = {}`; with no enabled mode omit elicitation entirely. Preserve the preceding empty default. Pin to [schema commit 0e486bcd](https://github.com/agentclientprotocol/agent-client-protocol/blob/0e486bcd6a5ec97bcb31bc97c360996f7f2dc6a7/schema/v2/schema.json), `$defs.ClientCapabilities` and `$defs.ElicitationCapabilities`, fetched during planning. Do not add auth/filesystem/terminal or AIR markers.

- [ ] Create one `ACPV2SessionRunnerTests` suite with a reusable frame-writing fake, real temporary persistence and event gates. Reuse existing bootstrap/decision transport helpers when compatible; do not copy the polling helper or create scenario-sliced test files.
- [ ] Add `freshRunnerInstallsBeforeBufferedMethodsAndNeverResetsLiveState`: fake initialize/new, buffer running/update/permission captures during setup, and assert bound projection, typed offers, exactly one default before live running and readiness only after both journals initialize. V1 selection reports replacementRequired and sends no session/new or fallback initialize.
- [ ] Parameterize `runnerAdvertisesExactlyItsInstalledInteractionHandlers` over none/form/url/both. Inspect exact initialize bytes and verify advertised offers are handled and unadvertised modes produce rejection handles, not offers. Extend bootstrap tests for invalid Support rejection before writes. A URL handler receives consent context without browser/process side effects.
- [ ] Add `explicitSubmitCorrelatesOptimisticRowsWithoutCompletingForeground`, parameterized by echo before/after acceptance. Use explicit local UUID, one row, acceptance evidence, then live running/idle for a single completion. Hold the first local submit and verify concurrent/reentrant submit returns busy before inserting another row. Not-ready, wrong session and non-user/duplicate rows return invalidInput/notReady without transcript mutation or write.
- [ ] Add `responsesDoNotBlockLaterCapturesOrReusedOrigins`: gate observation persistence, physically write the first answer, send a new request with the same RPC ID and assert its original new handle can be answered; interleave cancellation and update traffic. Reuse existing coordinator regression assertions rather than repeat transport internals.
- [ ] Record RED; implement runner composition and capability/context forwarding. Reserve the local submit slot before optimistic-row callbacks. Validate session ID, row kind/UUID and non-duplication before registration. Register row, recheck ownership, then call runtime.submit. Preserve the row and submission facts on rejection or uncertainty. Forward only projection's live completion generations. Recheck after every handler/event callback.
- [ ] Run `ACPProtocolNegotiationTests|ACPV2SessionBootstrapTests|ACPV2SessionRunnerTests|ACPV2RequestDecisionCoordinatorTests|ACPV2SessionProjectionTests`; record GREEN. Confirm no production `ACPSessionRunner` or manager edits.

## Task 5: Settle operations and withdraw the installation synchronously

**Files:** Runner, runner tests; only shared owner changes demonstrated necessary by the regressions. Keep transport gates authoritative.

**Interfaces:** Complete the stop/invalidate operations from Task 4. Use a runner-owned managed operation record for start/submit/decide continuations and worker cancellation. No public call may simply await a blocked child worker after the runner has promised prompt settlement. Caller cancellation is recorded in a Sendable lock-backed token before the MainActor hop, and propagated to the initiating child worker synchronously. Reuse existing cancellation patterns rather than introducing a new task framework.

- [ ] Add `withdrawalSettlesOperationsBeforeBlockedDependenciesResume`, parameterized across start/binding, update COMMIT, inbound COMMIT, submission registration, response intent and writer handoff. For explicit stop/invalidate, assert failure of any pending public operation and interaction withdrawal before releasing the gate; update/inbound-only cases assert terminal status without needing an unrelated operation. Verify no late physical bytes, offer, ACK of failed capture or successful completion after release. A writer's existing committed evidence remains authoritative; never turn cancellation into a fabricated not-written fact.
- [ ] Extend that matrix at callback boundaries for projection, optimistic-row registration and form validation. Install a successor only after explicit invalidation; assert the old runner cannot release the successor's projection epoch or mutate its rows. Predicate-only withdrawal vetoes at the next boundary, without claiming immediate notification during blocked I/O.
- [ ] Add `callerCancellationBeforeWorkerInstallationCannotEscapeWithdrawal`: cancel at operation registration, then allow a blocked physical writer to proceed while MainActor settlement is delayed. Assert no reply bytes and exactly one waiter settlement. Retain coordinator's immutable chosen reply and original intent/attempt keys; never retry with new identities.
- [ ] Add `sourceEndAndSetupDeadlineNeverFabricateCompletion`, parameterized by EOF during setup, EOF after buffered live running and setup deadline before binding completes. Post-ready session lifetime is not limited by the setup deadline. No fixed sleeps: inject/reuse the bootstrap deadline wait seam and await events. No `.serialized` trait.
- [ ] Record RED for each missing contract; implement idempotent terminal transitions. Mark the runner inactive first, cancel initiating workers and child authority, stop bootstrap/runtime/coordinator, settle registered waiters and withdraw/release projection, then notify observers. Guard reentrancy and ignore stale epoch callbacks. Do not shut down caller-owned transport or install fallback v1 behavior.
- [ ] Run the affected runner/bootstrap/runtime/decision/response owner and JSONRPCFrameWriter suites. After these pass, run the combined affected selection below once and inspect its nonzero summary.

```bash
rtk swift test --package-path Packages/AlasCore --filter 'ACPProtocolNegotiationTests|ACPV2InboundDeliveryTests|ACPV2SessionUpdateDeliveryTests|ACPV2SessionUpdateOwnerTests|ACPV2InboundReceiptOwnerTests|ACPV2ActivityStateTests|ACPV2SessionStateTests|ACPV2SessionProjectionTests|ACPV2SessionBootstrapTests|ACPV2AttachmentRuntimeTests|ACPV2RequestDecisionCoordinatorTests|ACPV2ResponseOwnerTests|ACPV2SessionRunnerTests|ACPBrokerRawClientTests|ACPRawReplyTests|ACPRawRPCDeliveryTests|JSONRPCFrameWriterTests'
swiftformat Alas AlasTests Packages --lint --reporter github-actions-log --cache ignore
git diff --check
```

## Final review and handoff

- [ ] Self-review the diff against every spec section and this plan's five review-focus inputs. Remove redundant tests and accidental public APIs. Record any unsupported behavior honestly.
- [ ] Obtain one fresh whole-branch reviewer under the preserved inline workflow, following repository model-selection guidance. Focus on capture ordering, receipt ownership, setup/submit cancellation, reentrancy and immutable response authority. The reviewer reads both design and plan plus the actual diff and verification logs.
- [ ] Classify findings and fix all accepted material issues in one combined pass. Add a failing regression for a discovered bug, rerun the affected checks, and record results. No rereview under the preserved user preference.
- [ ] Report exact tests and counts, lint/whitespace results, remaining broker/production/live limits and uncommitted related files. Commit/push/open a PR only when requested, using the actual final diff and no attribution. Preserve unrelated files and published history.

## Plan self-review

All design requirements map to Tasks 1–5. Task 1 covers exclusive ordered capture and independent RPC responses; Task 2 covers fresh journals, defaults and per-capture COMMIT; Task 3 covers canonical subject ordering; Task 4 covers composition, supported capabilities, explicit submits and typed interactions; Task 5 covers managed operations and terminal authority. The five review-focus scenarios each have a named test owner. No new broker reconstruction, UI or production-selection contract is implied. Implementation details left to the builder are lock storage, private helper factoring and concrete fake fixture reuse, not observable behavior.
