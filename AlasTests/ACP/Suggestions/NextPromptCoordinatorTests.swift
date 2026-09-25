import Combine
import Foundation
import Synchronization
import Testing
@testable import Alas

@MainActor
@Suite("NextPromptCoordinator", .timeLimit(.minutes(1)))
struct NextPromptCoordinatorTests {
    @MainActor
    private final class Generator: NextPromptGenerating {
        var requests: [NextPromptRequest] = []
        var pending: [CheckedContinuation<String?, Never>] = []
        var started: CheckedContinuation<Void, Never>?
        var unloading = false
        var unloadStarted: CheckedContinuation<Void, Never>?
        var drain: CheckedContinuation<Void, Never>?

        func generate(_ request: NextPromptRequest) async throws -> String? {
            requests.append(request)
            return await withCheckedContinuation { continuation in
                pending.append(continuation)
                started?.resume()
                started = nil
            }
        }
        func waitForStart() async {
            if !pending.isEmpty { return }
            await withCheckedContinuation { started = $0 }
        }
        func finish(_ text: String? = "Explain the tradeoff.") {
            pending.removeFirst().resume(returning: text)
            drain?.resume()
            drain = nil
        }
        func cancelAndUnload() async {
            unloading = true
            unloadStarted?.resume()
            unloadStarted = nil
            if !pending.isEmpty { await withCheckedContinuation { drain = $0 } }
            unloading = false
        }
        func waitForUnload() async {
            if unloading { return }
            await withCheckedContinuation { unloadStarted = $0 }
        }
        func retryAfterFailure() async {}
    }

    @MainActor
    private final class Fixture {
        let generator = Generator()
        var incarnation = UUID()
        var sessionID = "session"
        var promptID = 1
        var transcriptRevision: UInt64 = 1
        var draftRevision = 0
        var composerEpoch: UInt64 = 0
        var settingsGeneration: UInt64 = 0
        var modelGeneration: UInt64 = 0
        var eligible = true
        var coordinator: NextPromptCoordinator!
        init(clock: NextPromptInference.Clock = .init()) {
            coordinator = NextPromptCoordinator(engine: generator, clock: clock) { [weak self] in self?.snapshot }
        }
        var id: NextPromptRequestID {
            .init(sessionID: sessionID, incarnation: incarnation, promptID: promptID,
                  transcriptRevision: transcriptRevision, draftRevision: draftRevision,
                  composerEpoch: composerEpoch, settingsGeneration: settingsGeneration,
                  modelGeneration: modelGeneration)
        }
        var snapshot: NextPromptEligibilitySnapshot {
            .init(id: id, turns: [.init(user: "Compare these", assistant: "Here is the tradeoff")],
                  isEligible: eligible)
        }
        var turn: NextPromptCompletedTurn {
            .init(sessionID: id.sessionID, incarnation: incarnation, promptID: promptID,
                  userMessageID: UUID(), transcriptRevision: transcriptRevision)
        }
        func start() async {
            coordinator.completed(turn)
            await generator.waitForStart()
        }
        func finish() async {
            let task = coordinator.generationTask
            generator.finish()
            await task?.value
        }
    }

    @Test func offersOnceAndAcceptanceConsumesBeforeUndo() async {
        let fixture = Fixture()
        await fixture.start()
        #expect(fixture.generator.requests.count == 1)
        await fixture.finish()
        #expect(fixture.coordinator.takeOffer() == "Explain the tradeoff.")
        #expect(fixture.coordinator.takeOffer() == nil)
        fixture.draftRevision += 2
        fixture.coordinator.invalidate()
        fixture.coordinator.completed(fixture.turn)
        #expect(fixture.coordinator.offer == nil)
        #expect(fixture.generator.requests.count == 1)
    }

    @Test func draftTypingAndClearingRejectsLateResultAndAllowsNextTurn() async {
        let fixture = Fixture()
        await fixture.start()
        let oldTask = fixture.coordinator.generationTask
        fixture.draftRevision = 1
        fixture.eligible = false
        fixture.coordinator.invalidate()
        fixture.draftRevision = 2
        fixture.eligible = true
        fixture.coordinator.completed(fixture.turn)
        fixture.generator.finish()
        await oldTask?.value
        #expect(fixture.coordinator.offer == nil)
        #expect(fixture.generator.requests.count == 1)
        fixture.promptID = 2
        await fixture.start()
        await fixture.finish()
        #expect(fixture.coordinator.takeOffer() == "Explain the tradeoff.")
        #expect(fixture.generator.requests.count == 2)
    }

    @Test func recreatedSessionWithSameDurableIDRejectsOldResult() async {
        let fixture = Fixture()
        await fixture.start()
        fixture.incarnation = UUID()
        // Even a missed invalidation callback cannot bypass the full identity check.
        await fixture.finish()
        #expect(fixture.coordinator.offer == nil)
        await fixture.start()
        await fixture.finish()
        #expect(fixture.coordinator.takeOffer() != nil)
    }

    @Test func focusLeaveAndReturnRejectsLateResultsAndCannotReplayToken() async {
        let fixture = Fixture()
        await fixture.start()
        let oldTask = fixture.coordinator.generationTask
        fixture.eligible = false
        fixture.coordinator.invalidate()
        #expect(fixture.coordinator.offer == nil)
        fixture.eligible = true
        fixture.coordinator.completed(fixture.turn)
        fixture.generator.finish()
        await oldTask?.value
        #expect(fixture.coordinator.offer == nil)
        #expect(fixture.generator.requests.count == 1)
        fixture.promptID += 1
        await fixture.start()
        await fixture.finish()
        #expect(fixture.coordinator.takeOffer() != nil)
    }

    @Test func ineligibleEventIsConsumedBeforeSnapshotAndOlderCallbackCannotReplaceNewer() async {
        let fixture = Fixture()
        fixture.eligible = false
        let older = fixture.turn
        fixture.coordinator.completed(older)
        fixture.eligible = true
        fixture.coordinator.completed(older)
        #expect(fixture.coordinator.generationTask == nil)
        fixture.promptID = 2
        await fixture.start()
        await fixture.finish()
        fixture.coordinator.completed(older)
        fixture.coordinator.completed(fixture.turn)
        #expect(fixture.coordinator.takeOffer() != nil)
        #expect(fixture.generator.requests.count == 1)
    }

    @Test func inactiveCompletionIsConsumedWithoutDismissingActiveOffer() async {
        let fixture = Fixture()
        await fixture.start()
        await fixture.finish()
        let inactiveIncarnation = UUID()
        let inactiveTurn = NextPromptCompletedTurn(sessionID: "background", incarnation: inactiveIncarnation,
                                                   promptID: 1, userMessageID: UUID(), transcriptRevision: 1)
        fixture.coordinator.completed(inactiveTurn)
        #expect(fixture.coordinator.offer == "Explain the tradeoff.")
        fixture.coordinator.invalidate()
        fixture.sessionID = inactiveTurn.sessionID
        fixture.incarnation = inactiveIncarnation
        fixture.coordinator.completed(inactiveTurn)
        #expect(fixture.coordinator.generationTask == nil)
        #expect(fixture.generator.requests.count == 1)
    }

    @Test(arguments: ["eligibility", "draft", "focus", "transcript", "settings", "model", "incarnation", "session", "prompt"])
    func takeOfferRechecksEveryIdentityAndEligibilityWithoutCallback(_ field: String) async {
        let fixture = Fixture()
        await fixture.start()
        await fixture.finish()
        switch field {
        case "eligibility": fixture.eligible = false
        case "draft": fixture.draftRevision += 1
        case "focus": fixture.composerEpoch += 1
        case "transcript": fixture.transcriptRevision += 1
        case "settings": fixture.settingsGeneration += 1
        case "model": fixture.modelGeneration += 1
        case "incarnation": fixture.incarnation = UUID()
        case "session": fixture.sessionID = "other"
        default: fixture.promptID += 1
        }
        #expect(fixture.coordinator.takeOffer() == nil)
        #expect(fixture.coordinator.offer == nil)
    }

    @Test func invalidationClearsIdentityBeforePublishingAndAcceptanceIsNotReentrant() async {
        let fixture = Fixture()
        await fixture.start()
        await fixture.finish()
        var reentrantAcceptance: String?
        let observation = fixture.coordinator.$offer.dropFirst().sink { value in
            if value == nil { reentrantAcceptance = fixture.coordinator.takeOffer() }
        }
        // A publisher fires before its backing property changes.
        fixture.coordinator.invalidate()
        #expect(reentrantAcceptance == nil)
        withExtendedLifetime(observation) {}
    }

    private func readySession(_ session: ACPSession = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")) -> (ACPSession, NextPromptCompletedTurn, NextPromptEligibilitySnapshot.Environment) {
        session.agentState = .ready
        let userID = session.recordUserPrompt(text: "Explain this", attachments: [])
        session.transcript.appendMessage(.agent(id: UUID(), StreamingText("Here is the answer.")))
        let turn = NextPromptCompletedTurn(sessionID: session.id, incarnation: session.incarnation,
                                          promptID: session.allocatePromptID(), userMessageID: userID,
                                          transcriptRevision: session.transcript.messagesGeneration)
        var environment = NextPromptEligibilitySnapshot.Environment()
        environment.isEnabled = true
        environment.hasVerifiedModel = true
        environment.isRuntimeAvailable = true
        environment.isAppActive = true
        environment.isActiveVisibleWriter = true
        environment.hasComposerFocus = true
        return (session, turn, environment)
    }

    @Test func liveProjectionKeepsUsableTextAndFullIdentity() throws {
        let (session, turn, environment) = readySession()
        let snapshot = try #require(NextPromptEligibilitySnapshot.live(session: session, turn: turn, environment: environment))
        #expect(snapshot.isEligible)
        #expect(snapshot.id.incarnation == session.incarnation)
        #expect(snapshot.id.draftRevision == session.composerDraftRevision)
        #expect(snapshot.turns == [.init(user: "Explain this", assistant: "Here is the answer.")])
    }

    @Test(arguments: ["enabled", "verified", "runtime", "app", "writer", "focus", "paste/drop/image", "selection",
                      "IME", "dictation", "picker", "prompt", "fork/delegation"])
    func liveProjectionRejectsExternalBlockers(_ blocker: String) {
        let (session, turn, initial) = readySession()
        var environment = initial
        switch blocker {
        case "enabled": environment.isEnabled = false
        case "verified": environment.hasVerifiedModel = false
        case "runtime": environment.isRuntimeAvailable = false
        case "app": environment.isAppActive = false
        case "writer": environment.isActiveVisibleWriter = false
        case "focus": environment.hasComposerFocus = false
        case "paste/drop/image": environment.hasPendingInput = true
        case "selection": environment.hasSelection = true
        case "IME": environment.hasMarkedText = true
        case "dictation": environment.isDictating = true
        case "picker": environment.isPickerPresented = true
        case "prompt": environment.hasPromptWork = true
        default: environment.hasForkOrDelegationWork = true
        }
        #expect(NextPromptEligibilitySnapshot.live(session: session, turn: turn, environment: environment)?.isEligible != true)
    }

    @Test(arguments: ["whitespace", "mention", "image", "stream", "queue", "auto-run", "recovery", "agent", "hydration", "fork", "pending work", "retry", "connection recovery"])
    func liveProjectionRejectsSessionBlockers(_ blocker: String) {
        let (session, turn, environment) = readySession()
        switch blocker {
        case "whitespace": session.composer.replaceDraft(.init(segments: [.text(" ")]))
        case "mention": session.composer.replaceDraft(.init(segments: [.mention(displayName: "a", uri: "file:///a")]))
        case "image": session.composer.replaceDraft(.init(segments: [.image(uri: "file:///a.png", mimeType: "image/png")]))
        case "stream": session.transcript.streamingState = .streaming
        case "queue": session.queue = [.init(blocks: [.text("queued")])]
        case "auto-run": session.autoRunEnabled = true
        case "recovery": session.contextRecoveryStatus = .restoring
        case "agent": session.agentState = .disconnected
        case "hydration": session.hydrationState = .loading
        case "pending work": session.nextPromptWorkCount = 1
        case "retry": session.apply(.sessionInfoUpdate(.init(title: nil, metadata: AnyCodable([
            "codex": AnyCodable(["error": AnyCodable(["willRetry": AnyCodable(true)])])
        ]))))
        case "connection recovery": _ = session.beginConnectionRecovery()
        default: session.forkRecord = .init(targetSessionID: "s", sourceSessionID: "parent", sourceAgentID: "codex",
                                            sourceBoundarySequence: 0, inheritedMessageCount: 0,
                                            phase: .ready, mechanism: .transcriptTransfer, contextDeliveryPending: true)
        }
        #expect(NextPromptEligibilitySnapshot.live(session: session, turn: turn, environment: environment)?.isEligible != true)
    }

    @Test(arguments: ["draft", "messages", "stream", "queue", "permission", "question", "plan", "auto-run", "recovery", "prompt"])
    func sessionActivityClearsOfferSynchronously(_ activity: String) async {
        let (session, turn, environment) = readySession()
        let generator = Generator()
        let coordinator = NextPromptCoordinator(engine: generator) {
            .live(session: session, turn: turn, environment: environment)
        }
        let observation = session.nextPromptActivity.sink { coordinator.invalidate() }
        coordinator.completed(turn)
        await generator.waitForStart()
        let task = coordinator.generationTask
        generator.finish()
        await task?.value
        #expect(coordinator.offer != nil)
        switch activity {
        case "draft": session.composer.replaceDraft(.init(segments: [.text("x")]))
        case "messages": session.transcript.appendMessage(.systemNotice(id: UUID(), text: "changed"))
        case "stream": session.transcript.streamingState = .streaming
        case "queue": session.queue.append(.init(blocks: [.text("new work")]))
        case "permission": session.transcript.pendingPermission = .init(id: .string("p"), params: .init(
            sessionId: "s", toolCall: .init(toolCallId: "t"), options: []))
        case "question": session.transcript.pendingQuestion = .init(id: .string("q"), params: .init(
            toolCallId: "t", title: nil, questions: []))
        case "plan": session.transcript.pendingPlan = .init(id: .string("plan"), params: .init(
            toolCallId: "t", name: "Plan", overview: "", plan: "Plan", todos: [], isProject: false, phases: []))
        case "auto-run": session.autoRunEnabled = true
        case "recovery": session.contextRecoveryStatus = .restoring
        default: _ = session.allocatePromptID()
        }
        #expect(coordinator.offer == nil)
        #expect(coordinator.takeOffer() == nil)
        #expect(NextPromptEligibilitySnapshot.live(session: session, turn: turn, environment: environment) == nil)
        coordinator.completed(turn)
        #expect(coordinator.generationTask == nil)
        withExtendedLifetime(observation) {}
    }

    @Test(arguments: [false, true])
    func transcriptInvalidatesBeforeArrayAndBufferObserversCanAccept(streaming: Bool) async throws {
        let (session, turn, environment) = readySession()
        let generator = Generator()
        let coordinator = NextPromptCoordinator(engine: generator) {
            .live(session: session, turn: turn, environment: environment)
        }
        let activity = session.nextPromptActivity.sink { coordinator.invalidate() }
        coordinator.completed(turn)
        await generator.waitForStart()
        let task = coordinator.generationTask
        generator.finish()
        await task?.value
        var accepted: String?
        let published: AnyCancellable
        if streaming {
            guard case .agent(_, _, let buffer) = session.transcript.messages.last else {
                Issue.record("Expected an agent buffer")
                return
            }
            published = buffer.objectWillChange.sink { accepted = coordinator.takeOffer() }
            session.apply(.agentMessageChunk(.text(" More output.")))
        } else {
            published = session.transcript.$messages.dropFirst().sink { _ in accepted = coordinator.takeOffer() }
            session.transcript.appendMessage(.systemNotice(id: UUID(), text: "mutation"))
        }
        #expect(accepted == nil)
        #expect(coordinator.offer == nil)
        withExtendedLifetime((activity, published)) {}
    }

    @Test(arguments: [false, true])
    func queueOrPermissionArrivalAndRemovalCannotResurrectPendingResult(permission: Bool) async {
        let (session, firstTurn, environment) = readySession()
        var turn = firstTurn
        let generator = Generator()
        let coordinator = NextPromptCoordinator(engine: generator) {
            .live(session: session, turn: turn, environment: environment)
        }
        let observation = session.nextPromptActivity.sink { coordinator.invalidate() }
        coordinator.completed(turn)
        await generator.waitForStart()
        let oldTask = coordinator.generationTask
        if permission {
            session.transcript.pendingPermission = .init(id: .string("p"), params: .init(
                sessionId: "s", toolCall: .init(toolCallId: "t"), options: []))
            session.transcript.pendingPermission = nil
        } else {
            session.queue.append(.init(blocks: [.text("queued")]))
            session.queue.removeAll()
        }
        coordinator.completed(turn)
        generator.finish()
        await oldTask?.value
        #expect(coordinator.offer == nil)
        #expect(generator.requests.count == 1)
        let userID = session.recordUserPrompt(text: "Follow up", attachments: [])
        session.transcript.appendMessage(.agent(id: UUID(), StreamingText("Another answer")))
        turn = .init(sessionID: session.id, incarnation: session.incarnation, promptID: session.allocatePromptID(),
                     userMessageID: userID, transcriptRevision: session.transcript.messagesGeneration)
        coordinator.completed(turn)
        await generator.waitForStart()
        let newTask = coordinator.generationTask
        generator.finish()
        await newTask?.value
        #expect(coordinator.takeOffer() != nil)
        #expect(generator.requests.count == 2)
        withExtendedLifetime(observation) {}
    }

    @Test(arguments: ["settings", "model", "app", "selection", "IME", "pending input", "picker", "dictation", "remount", "memory"])
    func externalActivityCannotRestoreTheConsumedOpportunity(_ reason: String) async {
        let fixture = Fixture()
        await fixture.start()
        let task = fixture.coordinator.generationTask
        fixture.eligible = false
        fixture.coordinator.invalidate()
        switch reason {
        case "settings": fixture.settingsGeneration += 2
        case "model": fixture.modelGeneration += 2
        default: fixture.composerEpoch += 2
        }
        fixture.eligible = true
        fixture.coordinator.completed(fixture.turn)
        fixture.generator.finish()
        await task?.value
        #expect(fixture.coordinator.offer == nil)
        #expect(fixture.generator.requests.count == 1)
        fixture.promptID += 1
        await fixture.start()
        await fixture.finish()
        #expect(fixture.coordinator.takeOffer() != nil)
    }

    @Test func deadlineSuppressesImmediatelyWhileUncooperativeGenerationDrains() async {
        let clock = ManualClock()
        let fixture = Fixture(clock: clock.clock)
        await fixture.start()
        let oldTask = fixture.coordinator.generationTask
        clock.advance(.seconds(15))
        await fixture.generator.waitForUnload()
        #expect(fixture.coordinator.offer == nil)
        #expect(fixture.coordinator.generationTask == nil)
        #expect(fixture.generator.pending.count == 1)
        fixture.coordinator.completed(fixture.turn)
        fixture.generator.finish()
        await oldTask?.value
        #expect(fixture.coordinator.offer == nil)
        #expect(fixture.generator.requests.count == 1)
        fixture.promptID += 1
        await fixture.start()
        await fixture.finish()
        #expect(fixture.coordinator.takeOffer() != nil)
    }

    @Test func lateResultChecksDeadlineEvenWhenTimerHasNotResumed() async {
        let clock = ManualClock(holdTimers: true)
        let fixture = Fixture(clock: clock.clock)
        await fixture.start()
        clock.advance(.seconds(16))
        await fixture.finish()
        #expect(fixture.coordinator.offer == nil)
    }

    @Test func replacementWaitsForDrainAndItsDeadlineIncludesThatWait() async {
        let clock = ManualClock()
        let fixture = Fixture(clock: clock.clock)
        await fixture.start()
        let oldTask = fixture.coordinator.generationTask
        fixture.promptID += 1
        fixture.coordinator.completed(fixture.turn)
        let replacement = fixture.coordinator.generationTask
        await fixture.generator.waitForUnload()
        #expect(fixture.generator.requests.count == 1)
        clock.advance(.seconds(16))
        fixture.generator.finish()
        await oldTask?.value
        await replacement?.value
        #expect(fixture.coordinator.offer == nil)
        #expect(fixture.generator.requests.count == 1)
    }

    @Test(arguments: ["visibility", "lease", "observed lease", "teardown", "shutdown"])
    func managerLifecycleInvalidatesBeforeReturning(_ event: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ACPSessionStore(path: root.appendingPathComponent("session.sqlite").path)
        let manager = ACPSessionManager(worktreeId: "w", worktreePath: root.path, store: store)
        let (session, turn, environment) = readySession(manager.createSession(id: "s", agentId: "codex", autoRunDefault: false))
        await manager.flushPersistence()
        manager.markSessionVisible(id: session.id)
        manager._ownedLeases.insert(session.id)
        let generator = Generator()
        let coordinator = NextPromptCoordinator(engine: generator) {
            .live(session: session, turn: turn, environment: environment)
        }
        let activity = session.nextPromptActivity.sink { coordinator.invalidate() }
        var ended = false
        let teardown = session.nextPromptTeardown.sink {
            ended = true
            coordinator.sessionEnded(incarnation: session.incarnation)
        }
        coordinator.completed(turn)
        await generator.waitForStart()
        let task = coordinator.generationTask
        generator.finish()
        await task?.value
        #expect(coordinator.offer != nil)
        switch event {
        case "visibility": manager.unmarkSessionVisible(id: session.id)
        case "lease": manager._ownedLeases.remove(session.id)
        case "observed lease":
            _ = try store.seizeLease(sessionId: session.id, instanceId: "other", pid: Int64(getpid()),
                                     now: Int64(Date().timeIntervalSince1970))
            #expect(await manager.heartbeatTick(sessionId: session.id))
        case "teardown": manager.closeSession(id: session.id)
        default: manager.shutdownBackgroundTasks()
        }
        #expect(coordinator.offer == nil)
        #expect(coordinator.takeOffer() == nil)
        #expect(ended == (event == "teardown" || event == "shutdown"))
        manager.shutdownBackgroundTasks()
        withExtendedLifetime((activity, teardown)) {}
    }
}

private final class ManualClock: Sendable {
    struct State {
        var now = ContinuousClock.now
        var holdTimers = false
        var waiters: [UUID: (ContinuousClock.Instant, CheckedContinuation<Void, Error>)] = [:]
    }
    private let state = Mutex(State())
    init(holdTimers: Bool = false) {
        state.withLock { $0.holdTimers = holdTimers }
    }
    var clock: NextPromptInference.Clock {
        .init(now: { self.state.withLock { $0.now } }, sleep: { deadline in
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    self.state.withLock {
                        if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                        else if $0.now >= deadline && !$0.holdTimers { continuation.resume() }
                        else { $0.waiters[id] = (deadline, continuation) }
                    }
                }
            } onCancel: {
                self.state.withLock { $0.waiters.removeValue(forKey: id)?.1.resume(throwing: CancellationError()) }
            }
        })
    }
    func advance(_ duration: Duration) {
        state.withLock {
            $0.now = $0.now.advanced(by: duration)
            guard !$0.holdTimers else { return }
            let now = $0.now
            for (id, waiter) in $0.waiters.filter({ $0.value.0 <= now }) {
                $0.waiters[id] = nil
                waiter.1.resume()
            }
        }
    }
}
