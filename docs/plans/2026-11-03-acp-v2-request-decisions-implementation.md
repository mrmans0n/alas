# ACP v2 request decisions implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Turn retained session-scoped v2 interactive requests into validated, attachment-bound decisions sent through the existing durable response owner.

**Architecture:** Add lossless typed request interpretation and a conservative form validator in AlasACP. Expose reliable inbound/lifecycle callbacks from the existing runtime, then install an optional MainActor coordinator that claims one decision per original origin and delegates exact replies to runtime.respond. Keep request cancellation, URL observations and transport facts separate from foreground lifecycle.

**Tech stack:** Swift, Swift Testing, AlasCore, LSPJSONValue, existing SQLite-backed inbound/response ledgers and concrete stdio/broker facades.

**Spec:** `docs/plans/2026-11-03-acp-v2-request-decisions-design.md`, approved in conversation.

## Global constraints

- Selected request contracts are pinned to ACP commit `0e486bcd6a5ec97bcb31bc97c360996f7f2dc6a7` and the blob IDs in the spec. No wholesale migration of other v2 schemas.
- Production remains v1-only. No manager/runner installation, UI/browser, filesystem/command execution, automatic approval, remembered policy, auth execution, outgoing session/cancel/close, queues, resume/adoption or schema change.
- Never answer directly through a transport or reconstruct a runtime.Request from a ledger row. The response owner retains immutable intent, insert-only attempt and uncertainty authority.
- No competing AsyncStream iterator, ACK authority, new-key retry or inferred foreground state. Notifications never gain response IDs.
- Preserve raw JSON/bytes and exact opaque identity, including arbitrary elicitation values. Do not reuse v1 request decoders or AnyCodable/Double conversions.
- User answers before readiness return correctable notReady without claiming a slot. Remote cancellation may claim a pending slot and wait for readiness.
- A claimed selected reply is not replaced by cancellation. Stop/ownership loss cancels initiating work and settles local waiters without fabricating not-written evidence.
- Preserve unrelated Ghostty/research changes and leave #2213 unchanged without separate authorization.
- Continue inline with no interim feature commits, one fresh final review and one combined material fix pass, no rereview. Commit/PR only when requested.
- Run focused package suites with actual nonzero counts, lint and whitespace. No native app/live adapter/SSH qualification is implied.

## Review focus

1. A synchronous observer releases a blocked writer during terminal notification. Task 2 must withdraw child response gates before invoking terminal lifecycle callbacks.
2. Cancellation arrives before a broker pending-snapshot capture with the same ID. Task 4 matches generation/cursor-qualified origins without cancelling later ID reuse.
3. Validation calls reenter stop or replacement before the decision claim. Task 3 rechecks ownership after the validator and before any durable intent.
4. Completion arrives before consent or while outcome persistence is blocked. Task 4 keeps the observation independent from reply delivery evidence.
5. Copied receipt handles, historical records and opposite RPC directions share ID text. Tasks 2–4 deduplicate by exact current origin and never mint authority from history or an outbound ID.

## Files and responsibilities

Source paths below share `Packages/AlasCore/Sources/`:

- Create `AlasACP/ACP/Protocol/ACPV2InteractiveRequest.swift`: classification, permission/elicitation payloads, typed decisions and lossless response framing.
- Create `AlasACP/ACP/Protocol/ACPV2FormAnswerValidator.swift`: conservative pure schema subset and explicit validation results.
- Modify `AlasSessions/ACP/Session/ACPV2AttachmentRuntime.swift`: retained inbound events, lifecycle events and origin-current response preflight, preserving existing optional callbacks.
- Modify `AlasSessions/ACP/Session/ACPV2SessionBootstrap.swift`: forward callbacks before runtime startup.
- Create `AlasSessions/ACP/Session/ACPV2RequestDecisionCoordinator.swift`: binding, opaque handles, local claim state, response tasks, cancellation matching and URL facts.
- Modify `AlasSessions/ACP/Session/ACPV2ResponseOwner.swift` and `ACPV2ResponseAttachment.swift` only for a read-only response eligibility inspection needed to avoid offering a new choice for a durable chosen origin. Do not change ledger semantics or schemas.
- Create `Packages/AlasCore/Tests/AlasCoreTests/ACPV2InteractiveRequestTests.swift` and `ACPV2RequestDecisionCoordinatorTests.swift`, one suite per new owning unit. Validator cases belong with the wire/decision suite; do not add scenario-sliced siblings.
- Extend existing `ACPV2AttachmentRuntimeTests.swift`, `ACPV2SessionBootstrapTests.swift`, `ACPBrokerRawClientTests.swift` and response-owner tests for their changed boundaries. Reuse existing event gates and real persistence fixtures.

## Task 1: Typed requests and conservative answer validation

**Interfaces**

Public `ACPV2InteractiveRequest` contains the decoded `ACPV2InboundDelivery.Header`, original raw value and `Classification`. `static func decode(frame: Data, upstreamSessionId: String, support: Support) throws -> Self` preserves a valid inbound header even when known params are malformed. Invalid envelope/JSON throws and cannot create a response handle.

`Classification` distinguishes permission, form, url, cancelRequest(requestId), elicitationComplete(elicitationId), unsupported(reason) and malformed(reason). Known notifications require absent envelope ID. Known request methods without an ID remain noninteractive diagnostics. Unsupported reasons distinguish unknown method, unadvertised method, unadvertised mode, unknown mode, request scope and wrong session.

Permission exposes title/description, typed tool_call/command/unknown subject, options and raw metadata. Form exposes raw schema/message/scope; URL exposes opaque elicitationId/full URI/message/scope. `Support` records local method/mode eligibility without changing initialization advertising. Request-scoped payloads are preserved but produce no ordinary decision handle.

`Decision` cases are selectPermission(optionID: String), cancelPermission, acceptElicitation(content: LSPJSONValue?), declineElicitation, cancelElicitation and reject(ProtocolError). `ProtocolError` is methodNotFound, invalidParams or requestCancelled with fixed codes -32601/-32602/-32800 and short English messages. Each classification exposes allowed rejection choices; unsupported requests never receive an automatic reply.

`@MainActor func responseFrame(for decision: Decision, formValidator: FormValidator) throws -> Data` validates exact method/ID/options/content semantics before encoding one JSON-RPC response. Use `LSPJSONValue.encodedData()` rather than Codable's generic JSON number conversion, then ACPRawReply.validateFrame. Never add a newline to the stored frame. Invalid user decisions are correctable errors, not wire errors sent to the agent.

`FormValidator = @MainActor (LSPJSONValue, LSPJSONValue?) -> ACPV2FormAnswerValidator.Result`; Result is valid, invalid(message) or unsupported(message). The default pure entry point is `static func validate(schema: LSPJSONValue, content: LSPJSONValue?) -> Result`.

Default subset decisions:
- Root object schema, properties object, optional required array of exact-unique strings. Missing property definitions for required entries are unsupported. Omitted root type is treated as object consistently with the selected schema default; a different explicit type is unsupported.
- Known property types string, number, integer, boolean and array of strings. Integer checks mathematical integrality of JSON numeric tokens without rounding or converting to Int/Double. Arrays support string enum or string anyOf choices. String enum/oneOf are mutually exclusive; exact-unique strings/options are required.
- Bounds supported are nonnegative integer minLength/maxLength counted in Unicode scalars, and minItems/maxItems. Invalid/conflicting bounds are unsupported. Noncanonical numeric representations of these schema counts may be conservatively unsupported, never truncated.
- Numeric minimum/maximum, pattern and known format validation are unsupported in the default. Unknown format is plain text as the selected contract specifies. Do not substitute ICU regex or rounded numeric comparisons. Caller validators can support additional/custom constraints.
- title, description, _meta and default are retained annotations, never answers. Unknown validation keywords are unsupported when applicable to a supplied value or required field. Optional unknown fields may be omitted. Unknown submitted property names are rejected by this conservative local validator; this is a local limitation, not a claim about JSON Schema's default additionalProperties behavior.
- Omitted/null content means no answers. Enforce required fields accordingly. For supplied known properties, null/type mismatch is invalid; arbitrary values for custom types remain representable and can be validated by an injected validator.

- [x] Write parameterized `permissionRequestsUseV2SubjectsAndExactOptions`: missing title, empty/duplicate options, byte-distinct IDs, absent/null/unknown subjects, native POSIX/Windows paths, string/integer RPC IDs and wrong session. Assert classification and retained raw fields, not v1 normalization.
- [x] Write `elicitationModesScopesAndResponsesPreserveOpaqueJSON` with missing/unknown mode, both/neither scopes, request scope, unadvertised method versus mode, and accepted nested object/array/null/1e999 values via an injected validator. Validate exact response ID/action and no narrowed values.
- [x] Write `defaultFormValidationNeverClaimsUnsupportedConstraints` covering required/optional unknown fields, enum conflicts, type/integer/array checks, Unicode scalar counts, length/item bounds, regex/numeric limits and unknown format. Assert unsupported versus invalid versus valid explicitly.
- [x] Run `rtk swift test --package-path Packages/AlasCore --filter ACPV2InteractiveRequestTests` using the existing isolated package runner if necessary. Confirm a meaningful missing-contract RED.
- [x] Implement the wire types, conservative validator and lossless framing. Notifications/invalid envelopes cannot produce a frame; invalid selection or content writes nothing. Required known subject fields are checked; schema-marked optional deserialize-on-error fields may fall back for interpretation while raw evidence remains preserved.
- [x] Run the same suite GREEN with a nonzero count. Record chosen unsupported constraints and source pin in the ledger. Do not commit yet.

## Task 2: Reliable inbound/lifecycle callbacks and response inspection

**Interfaces**

Add runtime `InboundEvent` with attachmentID, record, current capture source/receipt identity, diagnostic flag and optional original `Request`. Add `LifecycleEvent` with attachmentID and Status. Expose read-only `attachmentID: UUID`. These values are observations; only an original Request can reach respond.

Append optional `onInbound: (@MainActor (InboundEvent) throws -> Void)? = nil` and `onLifecycleChange: (@MainActor (LifecycleEvent) -> Void)? = nil` to runtime/bootstrap initializers. Bootstrap forwards both before setup default/start. Lifecycle events never require a second observations iterator. Add `Failure.decisions(message: String)` for throwing inbound callback failures.

Pass the inbound event after validated retention and before receipt consumption. Include notifications and diagnostic evidence, but only nondiagnostic valid inbound request headers get a Request. Preserve per-origin offer deduplication. Existing onRequest remains for integrations without this coordinator; it must not become a second answer authority.

Terminal lifecycle callbacks must run after active=false and synchronous response/inbound/update gate withdrawal, not between setting status and stopping the response owner. Nonterminal callbacks are followed by current-state checks before child startup or dispatch. If readiness causes queued work, dispatch tasks recheck actual status/epoch when they run.

Expose runtime `func inspectResponse(to request: Request) async throws -> ResponseAvailability`, with availability available, unavailable, observationLost or alreadyChosen. Define `ACPV2ResponseOwner.ResponseAvailability` as a public Sendable enum and expose it through a runtime typealias. Add response-owner `func inspect(request: ACPV2InboundLedgerRecord, delivery: ACPV2InboundDelivery?) async throws -> ResponseAvailability` for the implementation. Validate runtime ownership/epoch and concrete current-origin reconciliation, then inspect chosen state without mutation. Add `loadV2ResponseIntentPage(stream: ACPV2InboundLedgerStream, after: ACPV2ResponseLedgerContinuation?, maxRecords: Int, maxBytes: Int) async throws -> ACPV2ResponseLedgerPage<ACPV2ResponseIntent>` to ACPV2ResponseLedgerPersisting, matching the existing actor method. Read bounded pages of 128 records/1,048,576 bytes with cancellation/ownership checks between awaits and compare exact request identity, not only an ordinal. An existing intent is alreadyChosen regardless of attempt status; no attempt read is needed to permit a replacement choice. Read failure/oversized evidence yields observationLost. Restore no authority and send nothing. Actual respond still performs its own current-origin reconciliation and insert-only durable checks; inspection is an observation, never a write promise.

- [x] Extend runtime tests `retainedInboundCallbacksPreserveRequestsNotificationsAndDiagnostics`: check post-COMMIT visibility, original source, copied receipt dedup and zero Request for diagnostics/history. Reentrant callback stop/throw prevents ACK and successor offers.
- [x] Add `terminalLifecycleWithdrawsWriterAuthorityBeforeCallingObservers` using the actual frame writer blocked before its authorization boundary. A lifecycle observer releases it; assert no late write and no process-close claim. Also stop from restoring/ready callbacks and assert no child startup/dispatch after withdrawal.
- [x] Add bootstrap callback forwarding and runtime readiness observation assertions to existing bootstrap tests without claiming pre-session interaction support.
- [x] Add response-owner inspection cases: current fresh origin available, historical/removed origin unavailable, existing intent/attempt alreadyChosen and read failure observationLost. Assert no endpoint call or durable mutation.
- [x] Run focused affected suites RED, implement callbacks/inspection with post-await and post-callback fences, and forward the added read protocol requirement in existing ResponseJournal/gate fakes before running them GREEN. Inspect actual counts. No ledger schema or response retry rule changes.

## Task 3: Session-bound coordinator and one explicit decision

**Interfaces**

Create `@MainActor public final class ACPV2RequestDecisionCoordinator` with:
- `init(upstreamSessionId: String, support: ACPV2InteractiveRequest.Support, formValidator: FormValidator = ACPV2FormAnswerValidator.validate, isCurrent: @escaping @MainActor () -> Bool, onEvent: @escaping @MainActor (Event) -> Void)`.
- `func bind(to runtime: ACPV2AttachmentRuntime) throws`, exactly once, before runtime.start. Store a weak runtime reference; validate upstream context and capture attachmentID. Construction callbacks may capture the coordinator weakly; integration owns both lifetimes.
- `func receive(_ event: ACPV2AttachmentRuntime.InboundEvent) throws`, `func runtimeDidChange(_ event: ACPV2AttachmentRuntime.LifecycleEvent)` and `func stop()`.
- `func decide(_ handle: Handle, decision: ACPV2InteractiveRequest.Decision) async throws -> ACPV2ResponseOwner.Receipt`.
- `Handle` exposes typed payload/evidence but has private coordinator nonce/origin identity. `Event` reports offers, classified diagnostics, withdrawn handles, response facts and URL observations. No public initializer mints a handle.
- `Failure`: invalidated, foreignHandle, notReady, alreadyChosen, invalidDecision, unsupportedValidation, unavailable, observationLost. Preserve the underlying typed response-owner error as the response result rather than flattening local written evidence into a string.

Maintain per-origin entry state pending/choosing/responding/withdrawn/resolved-or-uncertain, original Request, one chosen frame and fixed intent/attempt/key. Validate source/epoch, handle and readiness synchronously. Run answer validation and then recheck current ownership and pending state before claiming. Invalid/unsupported answers and notReady leave pending with no persistence. Duplicate valid calls fail alreadyChosen or return an already stored result; they never call runtime.respond again.

Before offering an ordinary decision, inspect current/durable response availability asynchronously while retaining the original capture. This inspection must not block inbound ingestion/ACK. A deferred offer rechecks entry identity and any intervening cancellation before presentation. AlreadyChosen withdraws ordinary affordances and reports evidence without sending. The final response owner remains authoritative if inspection races an external writer. Cancellation may claim the local pending slot while inspection is blocked, but cannot dispatch until inspection establishes availability; alreadyChosen reports that evidence without sending a differently chosen cancellation response.

The first valid choice synchronously marks choosing before any response await. Create one immutable envelope/intent/attempt/key. Stop/caller cancellation cancels the initiating task and promptly settles local waiters even if a dependency ignores cancellation; late results cannot publish success into an inactive coordinator. No automatic slot reopening after persistence or transport failure.

- [x] Write `decisionsCommitOneOriginalReplyAndNeverAcknowledgeTwice` with real SQLite and a concrete stdio writer hook. Assert intent+attempt visibility at the physical write boundary, exact original ID/result values, one frame, and unchanged consumption count after responding.
- [x] Write `invalidAnswersAreCorrectableBeforeTheDecisionClaim` for wrong permission option, invalid/unsupported form acceptance and notReady. Check zero intent/attempt/write before a later valid explicit decision succeeds.
- [x] Write `duplicateAndReentrantAnswersCannotCreateAnotherAttempt`: two concurrent valid answers plus a validator/onEvent that stops/replaces ownership. Assert the synchronous winner, no second operation key and no stale write after withdrawal.
- [x] Write `durableChosenOriginsDoNotBecomeFreshDecisionOffers` with existing intent/attempt and a gate that delays inspection while cancellation/stop occurs. Assert no automatic response or reconstructed handle.
- [x] Write `stopSettlesBlockedDecisionWaitersWithoutLateSuccess` across intent, attempt and observation gates; preserve outcomePersistence/local facts separately from durable receipts.
- [x] Run coordinator tests RED, implement the coordinator through runtime APIs only, then run coordinator/runtime/response suites GREEN. Keep request-scoped/auth interactions classified without ordinary decision handles.

## Task 4: Individual cancellation and URL workflow observations

Use the same coordinator entry/claim from Task 3. A known pending cancellation claims a method-defined cancel response synchronously and withdraws the public handle. Queue that reply until actual runtime readiness; never queue a user answer submitted before readiness. If a valid answer already claimed the slot, cancellation withdraws further interaction but leaves the same immutable reply worker/frame intact. No newly keyed replacement response.

Index cancellation by exact inbound RPC ID plus attachment/source identity, not toolCallId or an outbound prompt ID. Stdio uses original inbound sequence: unknown cancellation does not target a later newly issued request. Broker cancellation records may match a current pending-snapshot origin with the same generation/ID only when originCursor < cancellationCursor. A later reused ID is unaffected. Preserve qualified cancellation evidence for a delayed matching pending capture; do not restore live authority from passive history. Simultaneously active origins with the same inbound ID are ambiguous and receive no ordinary decision offer until exact provenance/current eligibility resolves them; never select an arbitrary dictionary entry. If identity/order is ambiguous, withhold a new decision and report a diagnostic.

Reserve URL elicitation identity at validated create registration, before consent. Track consent, response evidence and complete observation separately. Record matching complete during pending consent or blocked response storage; never complete the original RPC, change foreground state or manufacture written evidence. Unknown/duplicate completions have no side effect. Reuse of an elicitationId anywhere on the same coordinator attachment is unsupported; a new attachment has its own identity domain. Broker completion must follow the create origin cursor.

- [x] Parameterize `answerAndCancellationRespectTheFirstSynchronousClaim` for answer-first/cancel-first and blocked intent/attempt/write boundaries. Assert exactly the selected frame or method-defined cancellation frame, no rewrite and no second write. For cancellation during restoration, assert user notReady remains unclaimed and readiness later dispatches only the cancellation reply.
- [x] Add `cancelRequestNeverTargetsTheOppositeDirectionOrALaterReuse`: equal numeric/string inbound IDs, simultaneous outbound request ID, answered/unknown IDs and later reused inbound IDs. Assert no outgoing prompt cancellation and no successor answer mutation.
- [x] Extend RawBrokerFixture in ACPBrokerRawClientTests with parameterized `qualifiedCancellationMatchesDelayedPendingOrigins`: cancellation-before-pending-snapshot, old versus reused origin cursor, generation mismatch, copied captures and already-ACKed unanswered snapshots. Assert one exact handle/cancel response only for the matching original origin.
- [x] Add `urlCompletionIsIndependentOfConsentAndReplyPersistence`: completion before consent, after write while observation save is held, save failure with local written fact, known notWritten and uncertainty. Assert completion evidence retained without a durable success/foreground effect. Parameterize duplicate/reused/unknown elicitation IDs rather than separate scenario suites.
- [x] Add `explicitProtocolRejectionsUseTheSameDurableOwner` for unsupported method/mode/malformed params using allowed errors. Notifications/diagnostic captures cannot be rejected through a fabricated Request. No automatic rejection occurs merely by receiving the event.
- [x] Run these tests RED, implement cancellation/URL handling, then run all affected request/runtime/broker/response suites GREEN. Reuse existing gate helpers and narrow fixture extensions; no real browser/process execution.

## Task 5: Final verification and one review

- [x] Run the combined focused selection with actual counts: `ACPV2InteractiveRequestTests|ACPV2RequestDecisionCoordinatorTests|ACPV2AttachmentRuntimeTests|ACPV2SessionBootstrapTests|ACPBrokerRawClientTests|ACPV2InboundReceiptOwnerTests|ACPV2ResponseOwnerTests|ACPRawReplyTests|ACPRawRPCDeliveryTests|JSONRPCFrameWriterTests|ACPV2SessionProjectionTests`. Add any existing pure schema/identity suite touched by implementation. Use `/private/tmp/alas-ledger-test-command.sh FILTER LOG` if its confirmed cwd/cache configuration remains valid.
- [x] Run full SwiftFormat lint and tracked/new-file whitespace checks. Inspect source call sites to verify no production installer, capability advertisement or second stream consumer was introduced.
- [x] Update plan checkboxes and execution ledger with observed RED/GREEN counts, contract pin, rulings and validation limits. Do not infer closure of the earlier projection replay/provenance/metadata gaps.
- [x] Request one fresh final whole-diff review against the approved design, with the five Review focus cases and ledger. Regrade by actual effect. Reproduce Critical/Important findings and fix them in one combined RED/GREEN pass, then rerun affected suites. Record declined judgments and deferred Minors. No rereview.
- [x] Report behavior, exact checks, remaining limitations and costs of implementation choices. Keep feature changes uncommitted until the user asks to ship; preserve unrelated local changes.

## Self-review

The spec's selected contracts/validation map to Task 1, reliable retention/readiness/inspection to Task 2, public identity and durable decisions to Task 3, cancellation/URL/error policy to Task 4, and evidence/review to Task 5. Each review-focus case has a named behavioral regression. Interface names and callback types are consistent across tasks. Read-only inspection is explicitly nonauthoritative and cannot replace final response reconciliation. Terminal callbacks follow gate withdrawal; local invalid answers remain correctable; unknown outcomes never reopen the slot. No product code has been changed while writing this plan.

## Execution evidence

Completed inline on `nacho/acp-v2-request-decisions`, without interim feature commits. The final combined selection passed **141 tests in 12 suites** in `/private/tmp/alas-decisions-final-verified.log`. Full SwiftFormat lint passed with zero violations across 2789 files. Tracked and new feature files passed whitespace checks.

One fresh final review found two Important issues: nullable alternate elicitation scope and caller cancellation reaching a queued physical writer only after an actor hop. Both were reproduced before fixing. The same fix pass pinned dispatch-time ownership withdrawal settling an installed continuation and rejection-only handling of reused URL workflow IDs. No rereview was performed.

The tests establish package behavior with concrete stdio writer serialization, in-memory facades and real SQLite. They do not qualify native UI, production installation, published adapters, live sessions, SSH, CI, long-session performance, or the preceding projection slice's deferred replay/provenance/local-metadata matrix. Production capability advertising is unchanged. Stopping this optional coordinator withdraws its whole bound runtime; an individual choice or caller cancellation has its own lifetime. A stdio write failure can withdraw the facade before durable response observation; URL completion remains independent evidence.
