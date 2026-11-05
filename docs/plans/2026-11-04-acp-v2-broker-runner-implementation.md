# ACP v2 broker runner implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Run a fresh ACP v2 session through the broker with ordered durable method processing, exact reply origins and fenced broker metadata.

**Architecture:** Extend the existing ordered intake at the raw broker transport, where journal cursors, snapshot candidates and protected ACK cursors already meet. Reuse the existing runner, driven owners, projection and decision coordinator. Broker setup and cursor mirroring use the session lease; transport invalidation reaches the runner independently of blocked journal retention.

**Tech stack:** Swift, Swift Testing, AsyncStream, Synchronization.Mutex, existing SQLite persistence and raw-v2 helper protocol.

**Spec:** [Approved design](2026-11-04-acp-v2-broker-runner-design.md). Read both documents before execution.

**Implementation status:** Partial. The branch adds the ordered broker claim, snapshot staging and terminal invalidation with focused regressions. Task 1 still needs bounded replay watermarks, complete duplicate validation and broader ACK/RPC barrier tests. Tasks 2-4 and the final review have not run. Production selection is unchanged.

## Global constraints

- Fresh raw-v2 broker generation and replay/redelivery within that same live client attachment only.
- Production stays on v1. No manager selection, UI, queues, session/resume, outgoing cancel/close, SSH integration or live adapter qualification.
- Use Alas identity. Do not change client identity to unlock capabilities.
- Preserve original broker ID, generation, cursor, pending key, raw bytes, connection and consumption handle.
- ACK means durable receipt retention, not request resolution, user consent or operation success.
- No new schema or helper protocol change. Existing standalone split modes remain supported.
- Caller owns broker lifecycle. Runner stop must not close the helper session, kill the adapter or erase uncertain metadata.
- Preserve unrelated Ghostty/research changes and leave #2213 unchanged.
- Tests use event gates or existing deadline helpers, never fixed sleeps or new short per-read timers. No default serialization.
- Use Conventional Commits without agent attribution. Stage exact related paths only.

## Review focus

These boundary cases need explicit regressions in the owning tasks.

1. A broker that keeps appending cannot postpone the initial ordering barrier forever. Task 1 pins a captured tail rather than global idle.
2. A snapshot's conflicting duplicate or old unseen origin must not overwrite later canonical state. Task 1 pins rejection before delivery or ACK.
3. An ACK accepted remotely followed by a failed local mirror must withdraw the installation without claiming rollback. Tasks 2 and 4 pin the two facts separately.
4. Transport loss during a held COMMIT must withdraw availability and queued handoff before that COMMIT resumes. Tasks 1 and 3 pin the shared validity check.
5. An ID reused after physical reply handoff must remain answerable while old observation persistence is blocked. Tasks 3 and 4 pin exact origin inspection.

## File map and execution setup

Modify existing files by responsibility. Do not split existing suites into scenario-specific siblings.

- `Packages/AlasCore/Sources/AlasACP/ACP/Protocol/ACPV2OrderedIntake.swift`: original method stream, shared validity and independent broker control notifications.
- `Packages/AlasCore/Sources/AlasACP/ACP/Broker/{ACPBrokerClient,ACPRawBrokerTransport}.swift`: claim, ordered replay, staged snapshots, ACK protection and source withdrawal.
- `Packages/AlasCore/Sources/AlasSessions/ACP/Session/ACPSessionStore+V2Bootstrap.swift` and `ACPSessionPersistence.swift`: transactional fresh broker binding.
- `Packages/AlasCore/Sources/AlasSessions/ACP/Session/{ACPV2SessionBootstrap,ACPV2AttachmentRuntime,ACPV2SessionUpdateOwner,ACPV2InboundReceiptOwner}.swift`: validated fresh broker use of driven owners.
- `Packages/AlasCore/Sources/AlasSessions/ACP/Session/ACPV2SessionRunner.swift`: broker factory, start, stable keys, cursor mirror and terminal monitoring.
- Existing tests in `Packages/AlasCore/Tests/AlasCoreTests/{ACPBrokerRawClientTests,ACPV2SessionBootstrapTests,ACPV2AttachmentRuntimeTests,ACPV2SessionRunnerTests}.swift`: regressions at the owning layer.

Before editing product code, use the worktree workflow to create a new branch such as `nacho/acp-v2-broker-runner` from current merged main. Verify the existing worktree and branch owner first. Do not reuse another worktree's branch or disturb unrelated changes. Carry only the approved design and this plan into the implementation checkout. Record starting HEAD and test evidence in `.superpowers/sdd/2026-11-04-acp-v2-broker-runner/progress.md`.

Commands below run from the implementation checkout. `rtk swift test --package-path Packages/AlasCore --filter '<selection>'` is the focused test command. Isolated scratch/cache arguments may be added for this host without changing selection. Confirm an actual nonzero `Test run with N tests in M suites` result; exit status alone is insufficient. Documentation changes need no test run.

### Task 1: Claim and order broker captures at the transport

**Files:** Modify ordered intake, broker client and raw broker transport. Extend `ACPBrokerRawClientTests.swift` and its existing `RawBrokerFixture`.

**Interfaces:**

- Add `ACPBrokerClient.claimV2OrderedIntake() async throws -> ACPV2OrderedIntake` and `validateV2OrderedIntake(_ intake: ACPV2OrderedIntake?) throws`. Validation uses shared claim identity, connection and mode; no second actor call is required in synchronous attachment initialization.
- Extend `ACPV2OrderedIntake` with `public var isValid: Bool`, `public let controls: AsyncStream<Control>`, `public let invalidations: AsyncStream<String>` and nested `public enum Control: Sendable { case durableState(ACPBrokerDurableState); case invalidated(message: String) }`. Use the existing durable-state type from `ACPBrokerClient.swift`. Keep its current event enum and single-consumer claim.
- Internal `invalidate(message: String)` clears shared validity synchronously before yielding terminal control and finishing streams. Stdio has no broker durable-state controls. Its existing semantics remain unchanged apart from safe default validity.
- Only the raw transport publishes controls; the runner consumes them. Runtime consumes the separate one-shot `invalidations` stream, which carries the same terminal reason and validity change. Caller callbacks remain observations. Store unbounded terminal/control notifications, not a coalescing status buffer. Emit terminal invalidation once, including when it precedes consumer installation.

- [ ] **Step 1: Add failing transport regressions.** Extend the existing fake with explicit replay pages, captured tails and ACK recording. Add `orderedBrokerCapturesFollowJournalCursorsAcrossSnapshots()` with A update at cursor 1, B permission at 3, C update at 5 and an opening/early snapshot already containing B. Assert the ordered capture sequence is A/B/C, original B cursor/key/frame survive, split streams receive no duplicate, and one consumption of B releases only its original protection. Hold consumption of A and assert ACK stays below 1 while an independent registered RPC outcome resolves. Add parameterized `orderedBrokerReplayRejectsUnprovableOrigins(reason:)` for conflicting bytes/key, old unseen snapshot origin and no-progress page. Assert invalidity before later publication or ACK. Extend claim tests for legacy, started, terminated, foreign and copied claims. Add `growingBrokerTailDoesNotMoveTheCapturedReplayBarrier()` with the fixture appending after every attach; assert initial replay returns after its captured tail without requiring idle.
- [ ] **Step 2: Run RED.** Run the focused command with `ACPBrokerRawClientTests`. Record the missing ordered claim or violated capture/ACK assertions. Compiler errors must come from the missing contract, not broken fixture syntax.
- [ ] **Step 3: Implement the claim and replay.** Claim before start and never duplicate publication into split streams. Stage snapshot candidates separately from `seen`/delivered state, but protect their cursors immediately. Validate every page snapshot and exact duplicate identity. Deliver only the proven journal prefix in ascending cursor order. Match and remove staged copies when journal origins arrive. Once a captured snapshot tail is reached, unresolved candidates within that prefix are an observation failure, not late inserts. Keep outcome correlation and completion protection independent. Bound the initial replay by its captured validated tail; queue later progress for polling without moving that barrier. Never discard later fetched records or silently acknowledge them.
- [ ] **Step 4: Implement terminal validity.** Poll failure, context/generation replacement, stdout closure, write uncertainty and detach invalidate the claim before stream completion. Check the same validity inside broker send/exact-response and ACK paths immediately before helper I/O and after awaits. A helper call already accepted cannot be retracted. Preserve explicit uncertain evidence. Test invalidation while a fake helper call is gated and after it has accepted the handoff; distinguish prevented I/O from already-started uncertain I/O.
- [ ] **Step 5: Run GREEN and commit.** Run `ACPBrokerRawClientTests|ACPRawReplyTests|JSONRPCFrameWriterTests`. Existing pending-snapshot split-mode tests must pass. Commit only Task 1 paths with `feat(acp): order broker captures before runtime delivery`.

### Task 2: Persist fresh broker identity under the lease

**Files:** Modify `ACPSessionStore+V2Bootstrap.swift`, `ACPSessionPersistence.swift`. Extend `ACPV2SessionBootstrapTests.swift`, reusing real SQLite fixtures.

**Interfaces:**

- Add store and persistence actor method `public func bindV2FreshBroker(state: ACPBrokerDurableState, fence: ACPSessionLeaseFence) throws -> Bool`. The actor forwards to the store; its external call is awaited.
- Return `true` only after the exact fresh identity is recorded or verified idempotently. Return `false` for conflicting/stale state or lease loss. Storage failures throw. Require raw-v2, positive generation and ACK 0.
- Use existing `updateACPBrokerAcknowledgedCursor(sessionId:state:fence:)` for subsequent cursor mirrors. Never use broad `updateACPBrokerState` to replace source identity in this runner.

- [ ] **Step 1: Add failing persistence regressions.** Add `freshBrokerBindingRequiresTheCurrentLeaseAndEmptyHistory(reason:)`. Variants cover empty fields, identical identity at ACK 0, other ID/generation/context, nonzero ACK, remote binding, archived/recovery state, existing v2 update/inbound/submission history and a replaced lease. Assert only the two fresh cases succeed; rejected rows remain byte-for-byte equivalent in relevant identity/binding fields. Exercise the existing cursor updater with delayed old-generation and stale-lease states; assert the replacement row is untouched and current-generation ACKs never decrease. Fold overlapping existing assertions into this test rather than duplicate them.
- [ ] **Step 2: Run RED.** Run `ACPV2SessionBootstrapTests` and record the missing fresh binding API failure.
- [ ] **Step 3: Implement transactional binding.** Reuse `bindV2FreshSession` lease, recovery and history checks in the same write transaction as identity comparison and CAS. Permit entirely empty broker metadata or exact identical fresh metadata only. Reject partial metadata. Reuse columns and source comparison rules, including exact byte comparisons for opaque identifiers. Do not erase or compensate metadata after an uncertain remote operation.
- [ ] **Step 4: Run GREEN and commit.** Run `ACPV2SessionBootstrapTests`. Commit these paths with `feat(acp): fence fresh v2 broker identity binding`.

### Task 3: Drive the existing runtime from a validated broker claim

**Files:** Modify `ACPV2SessionBootstrap.swift`, `ACPV2AttachmentRuntime.swift`, `ACPV2SessionUpdateOwner.swift`, `ACPV2InboundReceiptOwner.swift`. Extend `ACPV2AttachmentRuntimeTests.swift` and broker tests where their fixture owns helper behavior.

**Interfaces:**

- Extend both existing broker attachment initializers with `orderedIntake: ACPV2OrderedIntake? = nil`. Keep bootstrap initialization async and runtime attachment initialization synchronous. Validate Task 1 claim identity before installation; keep the existing bootstrap claim restrictions.
- Keep `startFreshOrdered() async throws`, `prepareFreshOrdered() async throws` and `processOrdered(_:)` names and signatures. Permit a broker only through the validated fresh path; do not invoke independent historical owner replay.
- Combine ordered claim `isValid` with the runtime/owners' current predicate. A monitor for terminal controls is independent of the method-processing task. Durable-state controls are consumed by the runner in Task 4, not by a second iterator in runtime.
- To avoid sharing one control iterator, runtime observes validity through Task 1's separate one-shot `invalidations` stream. Runtime claims its sole iterator; the runner uses `controls`. Neither stream grants method or ACK authority.

- [ ] **Step 1: Add failing runtime regressions.** Extend the ordered runtime fixture with broker mode. Add `freshOrderedBrokerCommitsSubjectsBeforeLaterUpdates()` and assert A/B/C canonical order, B's subject committed and projected before offer, C remains later when inspection is gated, no fabricated update ordinal and no subject foreground completion. Add `brokerInvalidationWithdrawsWhileMethodCommitIsBlocked()` and gate retention, invalidate the claim, then assert observationLost, withdrawn affordances, settled local waiters and unknown foreground before releasing the gate. After release assert no offer, consumption or successor mutation. Assert historical local streams and duplicate consumer installation fail.
- [ ] **Step 2: Run RED.** Run `ACPV2AttachmentRuntimeTests|ACPV2SessionBootstrapTests` with the new broker variants; record the blocked fresh-source/claim contract.
- [ ] **Step 3: Implement driven broker preparation and terminal monitoring.** Keep empty-stream checks and one fresh default. Carry the opening snapshot boundary into live/history classification. Preserve original diagnostic provenance, including malformed broker frames; do not convert them through a stdio-only diagnostic constructor. Reuse committed permission-subject reduction, exact response inspection and existing synchronous post-callback ownership checks. Invalidate independently of a blocked FIFO and prevent late storage returns from restoring authority.
- [ ] **Step 4: Pin reply reuse and controls.** Reuse the broker ID-reuse test with old response observation held; ensure a new current origin remains offerable, while simultaneous pending ambiguity and stale keys remain unavailable. Extend the cursor-qualified cancellation/URL tests through ordered delivery, preserving selected replies and rejecting controls for later origins or another generation. Avoid duplicating decoder tests.
- [ ] **Step 5: Run GREEN and commit.** Run `ACPV2AttachmentRuntimeTests|ACPV2SessionBootstrapTests|ACPV2SessionUpdateOwnerTests|ACPV2RequestDecisionCoordinatorTests|ACPBrokerRawClientTests`. Commit Task 3 paths with `feat(acp): drive fresh broker sessions through ordered owners`.

### Task 4: Add broker construction and fenced startup to the runner

**Files:** Modify `ACPV2SessionRunner.swift`. Extend `ACPV2SessionRunnerTests.swift` with an in-memory broker fixture, sharing existing helper fixtures where practical. Update the approved design's status when complete.

**Interfaces:**

- Add `public static func makeBroker(session: ACPSession, client: ACPBrokerClient, persistence: ACPSessionPersistence, fence: ACPSessionLeaseFence, info: ACPImplementationInfo, interactions: InteractionHandlers = .init(), journals: ACPV2AttachmentRuntime.Journals? = nil, isCurrent: @escaping @MainActor () -> Bool, onEvent: @escaping @MainActor (Event) -> Void) async throws -> ACPV2SessionRunner`.
- Factory validates the destination and claims intake only. It performs no broker open or setup I/O. `start(params:deadline:)` retains ownership of all cancellable startup work.
- Replace stdio-only private storage with a private transport enum and deferred bootstrap attachment for broker. Keep public stdio initializer and start/submit/decide/stop APIs unchanged.
- Allocate one installation UUID at construction. Keys are `alas:v2:<installation UUID>:initialize`, `alas:v2:<installation UUID>:session-new` and `alas:v2:<installation UUID>:prompt:<submission UUID>`. Pass setup strings to bootstrap and the prompt key as `ACPBrokerOperationKey`. Never create a replacement key for retry.

- [ ] **Step 1: Add failing runner regressions.** Add `freshBrokerRunnerInstallsBeforeBufferedMethods()` to prove Alas identity, handler-derived capabilities, projection/decision installation and durable A/B/C delivery after fresh startup. Add `brokerRunnerRejectsExistingSourcesWithoutSetup(reason:)` covering adopted, legacy, initialized, nonzero prefix, persisted conflict/history and reused client. Assert no initialize/new dispatch and no foreign metadata replacement. Add `brokerSubmissionUsesOneStableKeyAndOneOptimisticRow(echoFirst:)`; assert acceptance is not foreground completion, duplicate submit is rejected and uncertain outcome never resends. Assert exact setup/prompt key shape and equality across all callbacks for the same operation.
- [ ] **Step 2: Run RED.** Run `ACPV2SessionRunnerTests`; record the missing broker factory or missing key/binding behavior.
- [ ] **Step 3: Implement broker startup.** Start control monitoring before open. Open via the managed start worker, verify fresh result and ownership, then await Task 2 binding before initialize/new. Buffer durable-state controls until identity is bound, then serialize fenced ACK mirrors; no callback may replace generation or write after epoch loss. The opening ACK 0 identity is committed before mirroring any progress observed during open. Use the existing bootstrap claim and Task 3 attachment. Recheck source validity/ownership around every await and user callback.
- [ ] **Step 4: Test and implement failure settlement.** Parameterize stop, ownership and source loss at open, binding, setup, method COMMIT and response handoff gates. Assert managed waiters finish before gates release, no late offer/ACK/optimistic mutation, and no helper close or process kill. Test remote ACK accepted followed by local mirror false/throw: retain the recorded remote ACK fact, withdraw locally and preserve metadata rather than claiming rollback. A later callback cannot update replacement identity. Caller detach remains explicit. No second control iterator or caller state writer is installed.
- [ ] **Step 5: Run focused GREEN.** Run `ACPV2SessionRunnerTests|ACPV2AttachmentRuntimeTests|ACPV2SessionBootstrapTests|ACPBrokerRawClientTests|ACPV2ResponseOwnerTests|ACPV2RequestDecisionCoordinatorTests`. Confirm nonzero suite/test counts and terminal success. Run `rtk swiftformat Alas AlasTests Packages --lint --reporter github-actions-log --cache ignore` and `git diff --check`. Format only related edited files if needed, then rerun affected checks. No app build is required for this package-only change.
- [ ] **Step 6: Review the final diff and commit.** Confirm spec acceptance items 1-9 have evidence and standalone stdio/split-mode broker behavior is unchanged. Record missing live qualification explicitly. Commit related runner/test/docs paths with `feat(acp): add fresh v2 broker runner`. Follow the chosen execution workflow's final review; fix material findings and rerun affected tests. Do not create a PR or merge without the user's requested publication step.

## Plan self-review

Spec coverage: claims, snapshot order, finite replay barrier and protected ACKs are Task 1; fresh identity and cursor fences are Task 2; driven durability, subjects, controls and independent invalidation are Task 3; keys, lifecycle, local ACK mirror failures and caller-owned detach are Task 4. All nine spec acceptance items have an owning test step. The two notification streams have distinct sole consumers and use one shared validity state. Signatures introduced above remain consistent between transport, bootstrap and runner. Implementation stays within the existing package and test suites.

Recommended execution is native in this session. These four tasks share transport and lifetime contracts; one implementer can maintain those contracts without repeated handoff, followed by the chosen workflow's fresh final review. This plan requires review before product edits.
