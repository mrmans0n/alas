import Foundation
import Testing
@testable import Alas

@MainActor
struct ComputerUseCoordinatorTests {
    private static let notes = ComputerUseAppIdentity(name: "Notes", bundleID: "com.apple.Notes", pid: 101)
    private static let mail = ComputerUseAppIdentity(name: "Mail", bundleID: "com.apple.mail", pid: 102)
    private static let keychain = ComputerUseAppIdentity(name: "Keychain Access", bundleID: "com.apple.keychainaccess", pid: 103)
    private static let alasDev = ComputerUseAppIdentity(name: "Alas Dev", bundleID: "io.nlopez.alas.dev", pid: 104)
    private static let windows: [UInt32: ComputerUseWindow] = [
        1: ComputerUseWindow(windowID: 1, title: "Note", frame: CGRect(x: 0, y: 0, width: 400, height: 300), app: notes),
        2: ComputerUseWindow(windowID: 2, title: "Inbox", frame: CGRect(x: 10, y: 10, width: 500, height: 400), app: mail),
        3: ComputerUseWindow(windowID: 3, title: "Login", frame: CGRect(x: 20, y: 20, width: 600, height: 500), app: keychain),
        4: ComputerUseWindow(windowID: 4, title: "Alas", frame: CGRect(x: 30, y: 30, width: 700, height: 500), app: alasDev),
    ]

    private static let saveTree = ComputerUseAXNode(
        role: "AXWindow", title: "Note", children: [ComputerUseAXNode(role: "AXButton", title: "Save", handle: 1)], handle: 0)

    private static func system(
        windows: [UInt32: ComputerUseWindow] = windows, treeComplete: Bool = true, recorder: Recorder? = nil
    ) -> ComputerUseSystem {
        let notes = notes
        let saveTree = saveTree
        return ComputerUseSystem(
            runningApps: { windows.values.map { (app: $0.app, windows: [$0]) } },
            window: { windows[$0] },
            screenshot: { _ in ComputerUseScreenshot(png: Data([0x89]), pixelSize: CGSize(width: 800, height: 600), scale: 2) },
            axTree: { _, _, _, _ in (saveTree, treeComplete, ComputerUseAXHandles()) },
            perform: { input, _, _, _ in
                recorder?.record(input)
                return .ax
            },
            focusState: { _ in nil },
            elementState: { _, _ in nil },
            elementMatches: { _, _, _, _ in true },
            secondsSinceUserInput: { 60 },
            frontmostPID: { nil },
            resolveApp: { _, _ in notes },
            openApp: {
                recorder?.recordOpen()
                return $0
            }
        )
    }

    private final class Calls {
        var interrupts: [String] = []
    }

    private struct Fixture {
        let coordinator: ComputerUseCoordinator
        let access: ComputerUseAccess
        let lockURL: URL
        let calls: Calls
        let recorder: Recorder
    }

    /// The wait is long by default so a slow runner never times out an approval a test answers.
    /// `recorder` also records the coordinator's sleeps, which return at once.
    private static func fixture(
        system: ComputerUseSystem = system(), approvalWait: Duration = .seconds(60),
        recorder: Recorder = Recorder(), allowed: [ComputerUseAppIdentity] = [],
        sleep: (@Sendable (Duration) async -> Void)? = nil
    ) -> Fixture {
        let lockURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-computer-use-\(UUID().uuidString)/computer-use.lock")
        let access = ComputerUseAccess(hostPID: 1, alwaysAllowed: { [] })
        let calls = Calls()
        let coordinator = ComputerUseCoordinator(
            system: system, access: access,
            readiness: { .ready },
            sessionLabel: { "Agent · \($0)" },
            persistAlwaysAllowed: { _ in },
            interrupt: { calls.interrupts.append($0) },
            lockURL: lockURL,
            approvalWait: approvalWait,
            sleep: sleep ?? { recorder.recordSleep($0) }
        )
        for app in allowed {
            access.record(.allowForSession, for: app, session: "s")
        }
        return Fixture(coordinator: coordinator, access: access, lockURL: lockURL, calls: calls, recorder: recorder)
    }

    private static func text(_ response: AlasCLIResponse) -> String? {
        guard case .text(let lines) = response else { return nil }
        return lines.first
    }

    @Test func approvalResumesTheWaitingCalls() async throws {
        let f = Self.fixture()
        let first = Task { await f.coordinator.perform(.init(action: .inspect, windowID: 1), sessionID: "s") }
        let second = Task { await f.coordinator.perform(.init(action: .screenshot, windowID: 1), sessionID: "s") }
        try await eventually("both calls waiting on one card") {
            f.coordinator.pendingApprovals.count == 1 && f.coordinator.waitingCallCount == 2
        }
        let pending = try #require(f.coordinator.pendingApprovals.first)
        #expect(pending.sessionID == "s" && pending.app == Self.notes)
        f.coordinator.answer(pending.id, .allowForTurn)
        let json = try #require(Self.text(await first.value))
        #expect(json.contains(#""elements""#) && json.contains(#""title":"Save""#))
        #expect(json.contains(#""truncated":false"#))
        #expect(try #require(Self.text(await second.value)).contains(#""image""#))
        #expect(f.coordinator.pendingApprovals.isEmpty)
    }

    @Test func inspectReportsTruncatedWhenTheTreeReadWasIncomplete() async throws {
        let f = Self.fixture(system: Self.system(treeComplete: false))
        f.access.record(.allowForSession, for: Self.notes, session: "s")
        let json = try #require(Self.text(await f.coordinator.perform(.init(action: .inspect, windowID: 1), sessionID: "s")))
        #expect(json.contains(#""truncated":true"#))
    }

    @Test func unansweredApprovalReturnsPendingAndKeepsTheCard() async {
        let f = Self.fixture(approvalWait: .milliseconds(200))
        let response = await f.coordinator.perform(.init(action: .screenshot, windowID: 1), sessionID: "s")
        #expect(response == .error("computer_approval_pending: Waiting for the user to approve Notes. Try again after they answer."))
        #expect(f.coordinator.pendingApprovals.count == 1)
    }

    @Test func staleApprovalExpiresAtTurnEnd() async throws {
        let f = Self.fixture(approvalWait: .milliseconds(200))
        let pending = "computer_approval_pending: Waiting for the user to approve Notes. Try again after they answer."
        #expect(await f.coordinator.perform(.init(action: .inspect, windowID: 1), sessionID: "s") == .error(pending))
        let stale = try #require(f.coordinator.pendingApprovals.first)
        f.coordinator.turnEnded(sessionID: "s")
        #expect(f.coordinator.pendingApprovals.isEmpty)
        // Answering the old card can't grant the next turn.
        f.coordinator.answer(stale.id, .allowForTurn)
        #expect(await f.coordinator.perform(.init(action: .inspect, windowID: 1), sessionID: "s") == .error(pending))
        let fresh = try #require(f.coordinator.pendingApprovals.first)
        #expect(fresh.id != stale.id)
    }

    @Test func cancelledCallReturnsCancelledAndKeepsTheCard() async throws {
        let f = Self.fixture()
        let call = Task { await f.coordinator.perform(.init(action: .inspect, windowID: 1, callID: "c1"), sessionID: "s") }
        try await eventually("approval card") { f.coordinator.waitingCallCount == 1 }
        #expect(await f.coordinator.perform(.init(action: .cancel, callID: "c1"), sessionID: "s") == .ok)
        #expect(await call.value == .error("computer_cancelled: The call was cancelled."))
        #expect(f.coordinator.pendingApprovals.count == 1)
    }

    @Test func failedCallKeepsTheLockWhileASiblingIsCapturing() async throws {
        let gate = TreeGate()
        let tree = (root: ComputerUseAXNode(role: "AXWindow", title: "Inbox"), complete: true, handles: ComputerUseAXHandles())
        var system = Self.system()
        system.runningApps = { [] }
        system.screenshot = { _ in throw ComputerUseSystemError.captureFailed("unused") }
        system.axTree = { window, _, _, _ in
            await gate.enter(window.windowID)
            if window.windowID == 1 { throw ComputerUseSystemError.captureFailed("Notes failed") }
            return tree
        }
        let f = Self.fixture(system: system)
        f.access.record(.allowForSession, for: Self.notes, session: "s")
        f.access.record(.allowForSession, for: Self.mail, session: "s")
        let failing = Task { await f.coordinator.perform(.init(action: .inspect, windowID: 1), sessionID: "s") }
        let sibling = Task { await f.coordinator.perform(.init(action: .inspect, windowID: 2), sessionID: "s") }
        try await eventually("both calls capturing") { gate.entered == [1, 2] }

        gate.open(1)
        #expect(await failing.value == .error("computer_capture_failed: Notes failed"))
        #expect(throws: ComputerUseDriverLock.Refusal.self) { try ComputerUseDriverLock.acquire(at: f.lockURL, label: "Other") }

        gate.open(2)
        #expect(Self.text(await sibling.value) != nil)
        #expect(f.coordinator.driver?.sessionID == "s")
        #expect(throws: ComputerUseDriverLock.Refusal.self) { try ComputerUseDriverLock.acquire(at: f.lockURL, label: "Other") }
        f.coordinator.turnEnded(sessionID: "s")
        try ComputerUseDriverLock.acquire(at: f.lockURL, label: "Next").release()
    }

    @Test func stopKeepsTheLockUntilTheCapturingCallExits() async throws {
        let gate = TreeGate()
        var system = Self.system()
        system.runningApps = { [] }
        system.screenshot = { _ in throw ComputerUseSystemError.captureFailed("unused") }
        system.axTree = { window, _, _, _ in
            await gate.enter(window.windowID)
            return (root: ComputerUseAXNode(role: "AXWindow", title: "Note"), complete: true, handles: ComputerUseAXHandles())
        }
        let f = Self.fixture(system: system)
        f.access.record(.allowForSession, for: Self.notes, session: "s")
        let call = Task { await f.coordinator.perform(.init(action: .inspect, windowID: 1, callID: "c1"), sessionID: "s") }
        try await eventually("call capturing") { gate.entered == [1] }

        await f.coordinator.stop(sessionID: "s")
        #expect(throws: ComputerUseDriverLock.Refusal.self) { try ComputerUseDriverLock.acquire(at: f.lockURL, label: "Other") }

        gate.open(1)
        #expect(await call.value == .error(ComputerUseCoordinator.Message.stopped))
        try ComputerUseDriverLock.acquire(at: f.lockURL, label: "Other").release()
    }

    @Test func driverShowsDuringTheFirstCaptureAndClearsWhenItFails() async throws {
        let gate = TreeGate()
        var system = Self.system()
        system.runningApps = { [] }
        system.screenshot = { _ in throw ComputerUseSystemError.captureFailed("unused") }
        system.axTree = { window, _, _, _ in
            await gate.enter(window.windowID)
            throw ComputerUseSystemError.captureFailed("Notes failed")
        }
        let f = Self.fixture(system: system)
        f.access.record(.allowForSession, for: Self.notes, session: "s")
        let call = Task { await f.coordinator.perform(.init(action: .inspect, windowID: 1), sessionID: "s") }
        try await eventually("call capturing") { gate.entered == [1] }
        #expect(f.coordinator.driver?.sessionID == "s")

        gate.open(1)
        #expect(await call.value == .error("computer_capture_failed: Notes failed"))
        #expect(f.coordinator.driver == nil)
    }

    @Test func reResolvedWindowOwnedByAnotherAppIsNotFound() async throws {
        let lookups = Counter()
        let notesWindow = Self.windows[1]!
        let recycled = ComputerUseWindow(windowID: 1, title: notesWindow.title, frame: notesWindow.frame, app: Self.mail)
        var system = Self.system()
        system.runningApps = { [] }
        system.window = { _ in lookups.next() == 1 ? notesWindow : recycled }
        let f = Self.fixture(system: system)
        f.access.record(.allowForSession, for: Self.mail, session: "s")
        let call = Task { await f.coordinator.perform(.init(action: .screenshot, windowID: 1), sessionID: "s") }
        try await eventually("approval card") { f.coordinator.pendingApprovals.count == 1 }
        f.coordinator.answer(try #require(f.coordinator.pendingApprovals.first).id, .allowForTurn)
        #expect(await call.value == .error("computer_window_not_found: No on-screen window 1. Call computer_apps again."))
    }

    @Test func busyWhenAnotherHolderHasTheLock() async throws {
        let f = Self.fixture()
        f.access.record(.allowForSession, for: Self.notes, session: "s")
        let other = try ComputerUseDriverLock.acquire(at: f.lockURL, label: "Other · Session")
        defer { other.release() }
        let response = await f.coordinator.perform(.init(action: .inspect, windowID: 1), sessionID: "s")
        #expect(response == .error("computer_busy: Another session is using the computer (Other · Session). Try again when it finishes."))
        #expect(f.coordinator.driver == nil)
    }

    @Test func sessionEndReleasesDriverAndCancelsPendingApproval() async throws {
        let f = Self.fixture()
        f.access.record(.allowForSession, for: Self.notes, session: "s")
        #expect(Self.text(await f.coordinator.perform(.init(action: .screenshot, windowID: 1), sessionID: "s")) != nil)
        #expect(f.coordinator.driver?.sessionID == "s")

        let waiting = Task { await f.coordinator.perform(.init(action: .inspect, windowID: 2), sessionID: "s") }
        try await eventually("approval card") { f.coordinator.pendingApprovals.count == 1 }
        f.coordinator.sessionEnded(sessionID: "s")
        f.coordinator.sessionEnded(sessionID: "s")

        #expect(await waiting.value == .error(ComputerUseCoordinator.Message.stopped))
        #expect(f.coordinator.driver == nil)
        #expect(f.coordinator.pendingApprovals.isEmpty)
        let next = try ComputerUseDriverLock.acquire(at: f.lockURL, label: "Next")
        next.release()
    }

    @Test func stopHoldsAcrossSessionEndUntilResume() async throws {
        let f = Self.fixture()
        await f.coordinator.stop(sessionID: "s")
        #expect(f.calls.interrupts == ["s"])
        f.coordinator.sessionEnded(sessionID: "s")
        #expect(f.coordinator.stoppedSessions == ["s"])
        let stopped = "computer_stopped: The user stopped computer use for this session. Ask them to resume it from the session's computer use badge."
        #expect(await f.coordinator.perform(.init(action: .apps), sessionID: "s") == .error(stopped))
        f.coordinator.resume(sessionID: "s")
        #expect(!f.coordinator.isStopped(sessionID: "s"))
        let json = try #require(Self.text(await f.coordinator.perform(.init(action: .apps), sessionID: "s")))
        let apps = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])["apps"] as? [[String: Any]]
        let byName = Dictionary(uniqueKeysWithValues: try #require(apps).map { ($0["name"] as? String ?? "", $0) })
        // A blocked app keeps its row, but its window titles and frames stay private.
        #expect(byName["Keychain Access"]?["approval"] as? String == "blocked")
        #expect((byName["Keychain Access"]?["windows"] as? [Any])?.isEmpty == true)
        #expect((byName["Notes"]?["windows"] as? [[String: Any]])?.first?["title"] as? String == "Note")
    }

    @Test func screenshotOfVanishedWindowReportsNotFound() async {
        let f = Self.fixture(system: Self.system(windows: [:]))
        let response = await f.coordinator.perform(.init(action: .screenshot, windowID: 42), sessionID: "s")
        #expect(response == .error("computer_window_not_found: No on-screen window 42. Call computer_apps again."))
        #expect(f.coordinator.pendingApprovals.isEmpty)
    }

    // MARK: - Actions

    @Test func clickByRefUsesTheInspectedElement() async throws {
        let recorder = Recorder()
        let f = Self.fixture(system: Self.system(recorder: recorder), recorder: recorder, allowed: [Self.notes])
        _ = await f.coordinator.perform(.init(action: .inspect, windowID: 1, query: "Save"), sessionID: "s")
        let json = try #require(Self.text(await f.coordinator.perform(.init(action: .click, windowID: 1, ref: "e2"), sessionID: "s")))
        guard case .click(.element(_, let handle), let button, let count) = try #require(recorder.inputs.first) else {
            Issue.record("expected an element click")
            return
        }
        #expect(handle == 1 && button == .left && count == 1)
        #expect(json.contains(#""delivery":"ax""#) && json.contains(#""action":"click""#))
        #expect(json.contains(#""elements":[{"#) && json.contains(#""title":"Save""#))
        // The post-action settle, and no takeover wait while the user is idle.
        #expect(recorder.sleeps == [.milliseconds(300)])
    }

    @Test func refsTheQueryLeftOutStillWork() async throws {
        let recorder = Recorder()
        let f = Self.fixture(system: Self.system(recorder: recorder), recorder: recorder, allowed: [Self.notes])
        // Only the window matches; the Save button is e2 all the same.
        let inspect = try #require(Self.text(await f.coordinator.perform(.init(action: .inspect, windowID: 1, query: "Note"), sessionID: "s")))
        #expect(!inspect.contains("Save"))
        #expect(Self.text(await f.coordinator.perform(.init(action: .click, windowID: 1, ref: "e2"), sessionID: "s")) != nil)
        guard case .click(.element(_, let handle), _, _) = try #require(recorder.inputs.first) else {
            Issue.record("expected an element click")
            return
        }
        #expect(handle == 1)
    }

    enum WindowChange: CaseIterable { case none, elements, focus, target, truncatedBefore, truncatedAfter }
    enum ActionKind { case click, key, type, scroll, drag }

    @Test(arguments: [
        (ActionKind.click, ComputerUseDelivered.ax, WindowChange.none, Warnings.noChange),
        (.click, .background, .none, Warnings.noChange + #" Retry with delivery: "direct"."#),
        (.click, .event, .elements, nil),
        (.click, .event, .focus, nil),
        // The clicked element changed although the listing and focus look the same.
        (.click, .background, .target, nil),
        // A cut-short read may have missed what changed.
        (.click, .background, .truncatedBefore, nil),
        (.click, .background, .truncatedAfter, nil),
        (.scroll, .background, .none, Warnings.noChange + #" Retry with delivery: "direct"."#),
        // Navigation keys and typing can legitimately change nothing a read shows: no retry hint.
        (.key, .background, .none, Warnings.noChange),
        (.type, .background, .none, Warnings.noChange),
        // A drag that changed nothing always says so, even when a read was cut short. Drags go
        // with the app activated, so there is no direct way left to suggest.
        (.drag, .activation, .none, Warnings.drag),
        (.drag, .activation, .truncatedAfter, Warnings.drag),
        (.drag, .activation, .elements, nil),
    ] as [(ActionKind, ComputerUseDelivered, WindowChange, String?)])
    func actionThatChangedNothingSaysSo(
        _ kind: ActionKind, _ delivered: ComputerUseDelivered, change: WindowChange, warning: String?
    ) async throws {
        let reads = Counter()
        let focusReads = Counter()
        let stateReads = Counter()
        let saveTree = Self.saveTree
        var system = Self.system()
        system.perform = { _, _, _, _ in delivered }
        // Read 1 is the inspect, 2 the window before the input, 3 the one after it.
        system.axTree = { _, _, _, _ in
            let read = reads.next()
            var tree = saveTree
            if change == .elements, read == 3 { tree.children.append(ComputerUseAXNode(role: "AXSheet", handle: 2)) }
            let cut = (change == .truncatedBefore && read == 2) || (change == .truncatedAfter && read == 3)
            return (tree, !cut, ComputerUseAXHandles())
        }
        system.focusState = { _ in
            let caret = change == .focus && focusReads.next() == 2 ? 5 : 0
            return ComputerUseWindowFingerprint.Focus(role: "AXTextArea", valueHash: 1, selectedRange: [caret, 0])
        }
        system.elementState = { _, _ in change == .target && stateReads.next() == 2 ? 2 : 1 }
        let f = Self.fixture(system: system, allowed: [Self.notes])
        _ = await f.coordinator.perform(.init(action: .inspect, windowID: 1), sessionID: "s")
        let command: ComputerUseCommand = switch kind {
        case .click: .init(action: .click, windowID: 1, ref: "e2")
        case .key: .init(action: .key, windowID: 1, keys: "down")
        case .type: .init(action: .type, windowID: 1, ref: "e2", text: "x")
        case .scroll: .init(action: .scroll, windowID: 1, ref: "e2", dy: 3)
        case .drag: .init(action: .drag, windowID: 1, ref: "e2", toRef: "e1")
        }
        let json = try #require(Self.text(await f.coordinator.perform(command, sessionID: "s")))
        let payload = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(payload["warning"] as? String == warning)
        #expect(payload["delivery"] as? String == delivered.delivery.rawValue)
    }

    /// `drag`: from e2 onto e1, so a failure names the end it is about.
    @Test(arguments: [
        (ComputerUseSystemError.staleElement, false,
         "computer_stale: The element ref e2 is no longer valid. Call computer_inspect on window 1 again."),
        (.outOfBounds, false, "computer_out_of_bounds: The point is outside window 1."),
        (.userActive, false, "computer_user_active: The user is using Notes right now. Try again in a moment."),
        (.staleDropElement, true,
         "computer_stale: The element ref e1 is no longer valid. Call computer_inspect on window 1 again."),
        (.staleElement, true,
         "computer_stale: The element ref e2 is no longer valid. Call computer_inspect on window 1 again."),
    ])
    func deliveryFailuresMapToTheirToolErrors(_ error: ComputerUseSystemError, drag: Bool, expected: String) async throws {
        var system = Self.system()
        system.perform = { _, _, _, _ in throw error }
        let f = Self.fixture(system: system, allowed: [Self.notes])
        _ = await f.coordinator.perform(.init(action: .inspect, windowID: 1), sessionID: "s")
        let command: ComputerUseCommand = drag
            ? .init(action: .drag, windowID: 1, ref: "e2", toRef: "e1")
            : .init(action: .click, windowID: 1, ref: "e2")
        #expect(await f.coordinator.perform(command, sessionID: "s") == .error(expected))
    }

    @Test func userTakingOverMidTypingStopsTheInput() async throws {
        let polls = Counter()
        var system = Self.system()
        system.frontmostPID = { 101 }
        // Idle for the takeover check before the input, busy by the next chunk.
        system.secondsSinceUserInput = { polls.next() == 1 ? 60 : 0.5 }
        system.perform = { _, _, _, interrupt in
            if interrupt() == .userActive { throw ComputerUseSystemError.userTookOver(typed: 5, of: 11) }
            return .event
        }
        let f = Self.fixture(system: system, allowed: [Self.notes])
        let response = await f.coordinator.perform(.init(action: .type, windowID: 1, text: "hello world"), sessionID: "s")
        #expect(response == .error("computer_user_active: The user started using Notes; stopped after typing 5 of 11 characters."))
    }

    @Test func anotherAlasCanBeSeenButNotDriven() async throws {
        let recorder = Recorder()
        let f = Self.fixture(system: Self.system(recorder: recorder), recorder: recorder, allowed: [Self.alasDev])
        #expect(Self.text(await f.coordinator.perform(.init(action: .inspect, windowID: 4), sessionID: "s")) != nil)
        let response = await f.coordinator.perform(.init(action: .key, windowID: 4, keys: "return"), sessionID: "s")
        #expect(response == .error("computer_blocked: Alas Dev can't be used by agents."))
        #expect(recorder.inputs.isEmpty)
    }

    @Test(arguments: ["cmd+q", "cmd+opt+q"])
    func quitChordsAreRefusedBeforeAnyInput(_ keys: String) async throws {
        let recorder = Recorder()
        let f = Self.fixture(system: Self.system(recorder: recorder), recorder: recorder, allowed: [Self.notes])
        let response = await f.coordinator.perform(.init(action: .key, windowID: 1, keys: keys), sessionID: "s")
        #expect(response == .error("computer_action_failed: Agents can't quit apps."))
        #expect(recorder.inputs.isEmpty)
    }

    /// `filteredReadRetitledTheNode`: a read that doesn't list the shown element finds another
    /// element in its place.
    enum RefExpiry: CaseIterable { case turnEnd, reinspectWithoutTheNode, elementChanged, filteredReadRetitledTheNode }

    @Test(arguments: RefExpiry.allCases)
    func refsExpireWithTheTurnAndOnReinspect(_ expiry: RefExpiry) async throws {
        let recorder = Recorder()
        let reads = Counter()
        let saveTree = Self.saveTree
        var system = Self.system(recorder: recorder)
        let retitled = ComputerUseAXNode(
            role: "AXWindow", title: "Note", children: [ComputerUseAXNode(role: "AXButton", title: "Delete", handle: 1)], handle: 0)
        // Only the first read still has the Save button.
        system.axTree = { _, _, _, _ in
            guard reads.next() > 1 else { return (saveTree, true, ComputerUseAXHandles()) }
            let later = expiry == .filteredReadRetitledTheNode ? retitled : ComputerUseAXNode(role: "AXWindow", title: "Note", handle: 0)
            return (later, true, ComputerUseAXHandles())
        }
        // The element behind the handle still exists, but now reads as another button.
        system.elementMatches = { _, handle, role, title in
            switch expiry {
            case .elementChanged: false
            // The live element is the retitled one, so only the ref's expected identity can catch it.
            case .filteredReadRetitledTheNode: handle == 1 && role == "AXButton" && title == "Delete"
            case .turnEnd, .reinspectWithoutTheNode: handle == 1 && role == "AXButton" && title == "Save"
            }
        }
        let f = Self.fixture(system: system, recorder: recorder, allowed: [Self.notes])
        _ = await f.coordinator.perform(.init(action: .inspect, windowID: 1, query: "Save"), sessionID: "s")
        switch expiry {
        case .turnEnd: f.coordinator.turnEnded(sessionID: "s")
        case .reinspectWithoutTheNode: _ = await f.coordinator.perform(.init(action: .inspect, windowID: 1, query: "Save"), sessionID: "s")
        case .filteredReadRetitledTheNode: _ = await f.coordinator.perform(.init(action: .inspect, windowID: 1, query: "Note"), sessionID: "s")
        case .elementChanged: break
        }
        let response = await f.coordinator.perform(.init(action: .click, windowID: 1, ref: "e2"), sessionID: "s")
        #expect(response == .error("computer_stale: The element ref e2 is no longer valid. Call computer_inspect on window 1 again."))
        #expect(recorder.inputs.isEmpty)
    }

    @Test func pointTargetsNeedAScreenshotAndMapThroughIt() async throws {
        let recorder = Recorder()
        let window = ComputerUseWindow(windowID: 1, title: "Note", frame: CGRect(x: 100, y: 50, width: 400, height: 300), app: Self.notes)
        let f = Self.fixture(system: Self.system(windows: [1: window], recorder: recorder), recorder: recorder, allowed: [Self.notes])
        let click = ComputerUseCommand(action: .click, windowID: 1, x: 200, y: 100)
        #expect(await f.coordinator.perform(click, sessionID: "s")
            == .error("computer_needs_screenshot: x/y are pixels in a screenshot of window 1. Call computer_screenshot first."))

        _ = await f.coordinator.perform(.init(action: .screenshot, windowID: 1), sessionID: "s")
        #expect(await f.coordinator.perform(.init(action: .click, windowID: 1, x: 2000, y: 2000), sessionID: "s")
            == .error("computer_out_of_bounds: The point is outside window 1."))
        #expect(Self.text(await f.coordinator.perform(click, sessionID: "s")) != nil)
        guard case .click(.point(let point), _, _) = try #require(recorder.inputs.first), recorder.inputs.count == 1 else {
            Issue.record("expected one point click")
            return
        }
        #expect(point == CGPoint(x: 200, y: 100))
    }

    enum CrossWindowDrop: CaseIterable { case mapped, outOfBounds, staleRef, otherApp }

    /// The drop end resolves in the end window: its screenshot, its frame and its refs. The end
    /// window is read back too, so a drop that changed only it isn't reported as no change.
    /// Another app's window is refused before any card or input.
    @Test(arguments: CrossWindowDrop.allCases)
    func dragIntoAnotherWindowUsesThatWindow(_ drop: CrossWindowDrop) async throws {
        let recorder = Recorder()
        let endReads = Counter()
        var windows = Self.windows
        windows[5] = ComputerUseWindow(windowID: 5, title: "Other", frame: CGRect(x: 10, y: 10, width: 500, height: 400), app: Self.notes)
        var system = Self.system(windows: windows, recorder: recorder)
        let saveTree = Self.saveTree
        // The end window's second read (the one after the drop) shows a new element.
        system.axTree = { window, _, _, _ in
            var tree = saveTree
            if window.windowID == 5, endReads.next() == 2 { tree.children.append(ComputerUseAXNode(role: "AXImage", handle: 2)) }
            return (tree, true, ComputerUseAXHandles())
        }
        system.perform = { input, _, _, _ in
            recorder.record(input)
            return .activation
        }
        let f = Self.fixture(system: system, recorder: recorder, allowed: [Self.notes])
        _ = await f.coordinator.perform(.init(action: .screenshot, windowID: 1), sessionID: "s")
        _ = await f.coordinator.perform(.init(action: .screenshot, windowID: 5), sessionID: "s")
        let drag: ComputerUseCommand = switch drop {
        case .mapped: .init(action: .drag, windowID: 1, x: 10, y: 10, toWindowID: 5, toX: 100, toY: 100)
        case .outOfBounds: .init(action: .drag, windowID: 1, x: 10, y: 10, toWindowID: 5, toX: 2000, toY: 2000)
        // Window 5 was never inspected, so e1 there is unknown even though window 1 has none either.
        case .staleRef: .init(action: .drag, windowID: 1, x: 10, y: 10, toWindowID: 5, toRef: "e1")
        case .otherApp: .init(action: .drag, windowID: 1, x: 10, y: 10, toWindowID: 2, toX: 100, toY: 100)
        }
        let response = await f.coordinator.perform(drag, sessionID: "s")
        switch drop {
        case .mapped:
            let json = try #require(Self.text(response))
            let payload = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            guard case .drag(.point(let start), .point(let point), let toWindow) = try #require(recorder.inputs.first) else {
                Issue.record("expected a point drag")
                return
            }
            // The end window sits at (10, 10); its screenshot has 2 pixels per point.
            #expect(start == CGPoint(x: 5, y: 5) && point == CGPoint(x: 60, y: 60) && toWindow?.windowID == 5)
            let end = try #require(payload["to_window"] as? [String: Any])
            #expect(end["window_id"] as? Int == 5 && (end["elements"] as? [Any])?.count == 3)
            // The start window looks the same, but the drop changed the end window.
            #expect(payload["warning"] == nil)
        case .outOfBounds:
            #expect(response == .error("computer_out_of_bounds: The point is outside window 5."))
            #expect(recorder.inputs.isEmpty)
        case .staleRef:
            #expect(response == .error("computer_stale: The element ref e1 is no longer valid. Call computer_inspect on window 5 again."))
            #expect(recorder.inputs.isEmpty)
        case .otherApp:
            #expect(response == .error("computer_action_failed: Dragging between different apps isn't supported yet."))
            #expect(f.coordinator.pendingApprovals.isEmpty && recorder.inputs.isEmpty)
        }
    }

    /// A drag always goes with the app in front, so like direct delivery it is refused, not
    /// waited out, while the user is active, whatever app they are in.
    @Test(arguments: [(60.0, true), (0.5, false)])
    func dragsAlwaysGoDirect(idleSeconds: TimeInterval, delivers: Bool) async throws {
        let recorder = Recorder()
        let directs = Recorder()
        var system = Self.system(recorder: recorder)
        system.secondsSinceUserInput = { idleSeconds }
        system.perform = { input, _, direct, _ in
            recorder.record(input)
            directs.recordCheck(direct)
            return .activation
        }
        let f = Self.fixture(system: system, recorder: recorder, allowed: [Self.notes])
        _ = await f.coordinator.perform(.init(action: .inspect, windowID: 1), sessionID: "s")
        let response = await f.coordinator.perform(.init(action: .drag, windowID: 1, ref: "e2", toRef: "e1"), sessionID: "s")
        if delivers {
            #expect(try #require(Self.text(response)).contains(#""delivery":"activation""#))
            #expect(directs.checks == [true])
        } else {
            #expect(response == .error("computer_user_active: The user is using Notes right now. Try again in a moment."))
            #expect(recorder.inputs.isEmpty && !recorder.sleeps.contains(ComputerUseCoordinator.takeoverPoll))
        }
    }

    /// An AX press in an Electron app may only focus the element: a click that changed nothing
    /// there is clicked once more with the pointer. Elsewhere, and after a change, it stands.
    @Test(arguments: [(true, false, true), (true, true, false), (false, false, false)])
    func electronClickThatChangedNothingIsRetriedWithThePointer(
        manualAccessibility: Bool, changed: Bool, retries: Bool
    ) async throws {
        let recorder = Recorder()
        let reads = Counter()
        let saveTree = Self.saveTree
        var system = Self.system(recorder: recorder)
        system.usesManualAccessibility = { $0 == 101 && manualAccessibility }
        // Read 1 is the inspect, 2 the window before the click, 3 the one after it.
        system.axTree = { _, _, _, _ in
            var tree = saveTree
            if changed, reads.next() >= 3 { tree.children.append(ComputerUseAXNode(role: "AXSheet", handle: 2)) }
            return (tree, true, ComputerUseAXHandles())
        }
        system.perform = { input, _, _, _ in
            recorder.record(input)
            if case .pointerClick = input { return .background }
            return .ax
        }
        let f = Self.fixture(system: system, recorder: recorder, allowed: [Self.notes])
        _ = await f.coordinator.perform(.init(action: .inspect, windowID: 1), sessionID: "s")
        let json = try #require(Self.text(await f.coordinator.perform(.init(action: .click, windowID: 1, ref: "e2"), sessionID: "s")))
        let payload = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let inputs = recorder.inputs
        guard case .click(.element(_, 1), .left, 1) = try #require(inputs.first) else {
            Issue.record("expected the element click first")
            return
        }
        if retries {
            guard inputs.count == 2, case .pointerClick(.element(_, 1)) = inputs[1] else {
                Issue.record("expected one pointer click at the element")
                return
            }
            #expect(payload["delivery"] as? String == "background" && payload["retried"] as? String == "pointer")
        } else {
            #expect(inputs.count == 1 && payload["delivery"] as? String == "ax" && payload["retried"] == nil)
        }
    }

    @Test func actionWaitsForUserIdleThenGivesUp() async throws {
        let recorder = Recorder()
        var system = Self.system(recorder: recorder)
        system.frontmostPID = { 101 }
        system.secondsSinceUserInput = { 0.5 }
        let f = Self.fixture(system: system, recorder: recorder, allowed: [Self.notes])
        let response = await f.coordinator.perform(.init(action: .key, windowID: 1, keys: "cmd+s"), sessionID: "s")
        #expect(response == .error("computer_user_active: The user is using Notes right now. Try again in a moment."))
        #expect(recorder.sleeps.reduce(.zero, +) == .seconds(10))
        #expect(recorder.inputs.isEmpty)
    }

    @Test func directDeliveryIsRefusedWhileTheUserIsActive() async throws {
        let recorder = Recorder()
        var system = Self.system(recorder: recorder)
        system.secondsSinceUserInput = { 0.5 }
        let f = Self.fixture(system: system, recorder: recorder, allowed: [Self.notes])
        let response = await f.coordinator.perform(.init(action: .key, windowID: 1, keys: "cmd+s", delivery: .direct), sessionID: "s")
        #expect(response == .error("computer_user_active: The user is using Notes right now. Try again in a moment."))
        #expect(recorder.sleeps.isEmpty && recorder.inputs.isEmpty)
    }

    @Test func turnEndDuringTheTakeoverWaitSendsNothing() async throws {
        let gate = TreeGate()
        let recorder = Recorder()
        let polls = Counter()
        var system = Self.system(recorder: recorder)
        system.frontmostPID = { 101 }
        // Busy for the first poll, idle after it.
        system.secondsSinceUserInput = { polls.next() == 1 ? 0.5 : 60 }
        let f = Self.fixture(system: system, recorder: recorder, allowed: [Self.notes]) { _ in await gate.enter(1) }
        let call = Task { await f.coordinator.perform(.init(action: .key, windowID: 1, keys: "cmd+s"), sessionID: "s") }
        try await eventually("takeover wait") { gate.entered == [1] }
        f.coordinator.turnEnded(sessionID: "s")
        gate.open(1)
        #expect(await call.value == .error("computer_cancelled: The call was cancelled."))
        #expect(recorder.inputs.isEmpty)
    }

    @Test func pointTargetIsRemappedWhenTheWindowMovedDuringTheTakeoverWait() async throws {
        let recorder = Recorder()
        let lookups = Counter()
        let polls = Counter()
        let original = ComputerUseWindow(windowID: 1, title: "Note", frame: CGRect(x: 100, y: 50, width: 400, height: 300), app: Self.notes)
        var moved = original
        moved.frame.origin = CGPoint(x: 1000, y: 1000)
        var system = Self.system(recorder: recorder)
        // The screenshot and the click resolve the original frame; the window moves while the user is busy.
        system.window = { [moved] _ in lookups.next() <= 2 ? original : moved }
        system.frontmostPID = { 101 }
        system.secondsSinceUserInput = { polls.next() == 1 ? 0.5 : 60 }
        let f = Self.fixture(system: system, recorder: recorder, allowed: [Self.notes])
        _ = await f.coordinator.perform(.init(action: .screenshot, windowID: 1), sessionID: "s")
        let response = await f.coordinator.perform(.init(action: .click, windowID: 1, x: 200, y: 100), sessionID: "s")
        #expect(response == .error("computer_out_of_bounds: The point is outside window 1."))
        #expect(recorder.inputs.isEmpty)
    }

    enum PostReadFailure: CaseIterable { case readFails, windowCloses }

    @Test(arguments: PostReadFailure.allCases)
    func failedPostActionReadStillReportsTheActionAndDropsRefs(_ failure: PostReadFailure) async throws {
        let recorder = Recorder()
        let reads = Counter()
        let lookups = Counter()
        let saveTree = Self.saveTree
        let window = Self.windows[1]!
        var system = Self.system(recorder: recorder)
        system.axTree = { _, _, _, _ in
            guard reads.next() == 1 || failure == .windowCloses else { throw ComputerUseSystemError.captureFailed("gone") }
            return (saveTree, true, ComputerUseAXHandles())
        }
        // Lookup 3 is the re-fetch before the post-action read.
        system.window = { _ in failure == .windowCloses && lookups.next() == 3 ? nil : window }
        let f = Self.fixture(system: system, recorder: recorder, allowed: [Self.notes])
        _ = await f.coordinator.perform(.init(action: .inspect, windowID: 1, query: "Save"), sessionID: "s")
        let click = ComputerUseCommand(action: .click, windowID: 1, ref: "e2")
        let json = try #require(Self.text(await f.coordinator.perform(click, sessionID: "s")))
        let postStateError = failure == .readFails ? "Capture failed: gone" : "Window 1 is no longer on screen"
        #expect(json.contains(#""post_state_error":"\#(postStateError)""#) && json.contains(#""elements":[]"#))
        #expect(await f.coordinator.perform(click, sessionID: "s")
            == .error("computer_stale: The element ref e2 is no longer valid. Call computer_inspect on window 1 again."))
        #expect(recorder.inputs.count == 1)
    }

    enum KeyedRelease: CaseIterable { case settled, stop, turnEnd, sessionEnd }

    @Test(arguments: KeyedRelease.allCases)
    func windowKeyedInTheBackgroundIsHandedBackOnce(_ release: KeyedRelease) async throws {
        let recorder = Recorder()
        let gate = TreeGate()
        let saveTree = Self.saveTree
        var system = Self.system(recorder: recorder)
        system.axTree = { _, _, _, _ in
            recorder.recordEvent("read")
            return (saveTree, true, ComputerUseAXHandles())
        }
        system.perform = { _, _, _, _ in ComputerUseDelivered(delivery: .background, keyedInBackground: true) }
        system.releaseBackgroundFocus = { recorder.recordEvent("release \($0.windowID)") }
        // The settle after the input waits until the test opens it.
        let f = Self.fixture(system: system, recorder: recorder, allowed: [Self.notes]) { _ in await gate.enter(1) }
        _ = await f.coordinator.perform(.init(action: .inspect, windowID: 1), sessionID: "s")
        let call = Task { await f.coordinator.perform(.init(action: .click, windowID: 1, ref: "e2"), sessionID: "s") }
        try await eventually("settling") { gate.entered == [1] }
        // Inspect and the change check's read; the window is still key.
        #expect(recorder.events == ["read", "read"])
        switch release {
        case .settled: break
        case .stop: await f.coordinator.stop(sessionID: "s")
        case .turnEnd: f.coordinator.turnEnded(sessionID: "s")
        case .sessionEnd: f.coordinator.sessionEnded(sessionID: "s")
        }
        if release != .settled {
            // Cut short: the stop or end hands it back while the action is still settling.
            try await eventually("handed back") { recorder.events == ["read", "read", "release 1"] }
        }
        gate.open(1)
        _ = await call.value
        // Settled: after the post-action read. Either way exactly once.
        #expect(recorder.events == (release == .settled ? ["read", "read", "read", "release 1"] : ["read", "read", "release 1"]))
    }

    enum Interruption: CaseIterable { case stop, turnEnd }

    @Test(arguments: Interruption.allCases)
    func stopDuringTypingSendsNoFurtherChunks(_ interruption: Interruption) async throws {
        let gate = TreeGate()
        let checks = Recorder()
        var system = Self.system()
        // Checks before its first chunk, then waits mid-sequence and checks before the next one.
        system.perform = { _, _, _, interrupt in
            checks.recordCheck(interrupt() == .cancelled)
            await gate.enter(1)
            let cancelled = interrupt() == .cancelled
            checks.recordCheck(cancelled)
            if cancelled { throw CancellationError() }
            return .event
        }
        let f = Self.fixture(system: system, allowed: [Self.notes])
        let call = Task { await f.coordinator.perform(.init(action: .type, windowID: 1, text: "hello world"), sessionID: "s") }
        try await eventually("typing") { gate.entered == [1] }
        switch interruption {
        case .stop: await f.coordinator.stop(sessionID: "s")
        case .turnEnd: f.coordinator.turnEnded(sessionID: "s")
        }
        gate.open(1)
        let expected = interruption == .stop ? ComputerUseCoordinator.Message.stopped : ComputerUseCoordinator.Message.cancelled
        #expect(await call.value == .error(expected))
        #expect(checks.checks == [false, true])
    }

    @Test(arguments: [
        ComputerUseAppIdentity(name: "Keychain Access", bundleID: "com.apple.keychainaccess", pid: 0),
        ComputerUseAppIdentity(name: "Alas Dev", bundleID: "io.nlopez.alas.dev", pid: 0),
    ])
    func openAppRefusesBlockedAppsWithoutLaunching(_ app: ComputerUseAppIdentity) async throws {
        let recorder = Recorder()
        var system = Self.system(recorder: recorder)
        system.resolveApp = { _, _ in app }
        let f = Self.fixture(system: system, recorder: recorder)
        let response = await f.coordinator.perform(.init(action: .openApp, name: app.name), sessionID: "s")
        #expect(response == .error("computer_blocked: \(app.name) can't be used by agents."))
        #expect(recorder.opens == 0)
        #expect(f.coordinator.pendingApprovals.isEmpty)
    }

    @Test func openAppRefusesALaunchedAppThatTurnsOutBlocked() async throws {
        let keychain = Self.keychain
        var system = Self.system()
        system.openApp = { _ in keychain }
        let f = Self.fixture(system: system, allowed: [Self.notes])
        let response = await f.coordinator.perform(.init(action: .openApp, name: "Notes"), sessionID: "s")
        #expect(response == .error("computer_blocked: Keychain Access can't be used by agents."))
    }

    enum WaitCase: CaseIterable { case appears, neverAppears, disappears, neverDisappears, windowCloses }

    @Test(arguments: WaitCase.allCases)
    func waitReturnsWhenTheQueryAppearsOrTimesOut(_ waitCase: WaitCase) async throws {
        let recorder = Recorder()
        let reads = Counter()
        let lookups = Counter()
        let window = Self.windows[1]!
        var system = Self.system(recorder: recorder)
        // Lookups 1 and 2 resolve the inspect and the wait; the window closes before the second poll.
        system.window = { _ in waitCase == .windowCloses && lookups.next() > 2 ? nil : window }
        // Read 1 is the inspect. "Done" shows up from read 4 on, never, or is always there.
        system.axTree = { _, _, _, _ in
            let read = reads.next()
            let done = switch waitCase {
            case .appears: read >= 4
            case .neverAppears, .disappears, .windowCloses: false
            case .neverDisappears: read > 1
            }
            let children = done ? [ComputerUseAXNode(role: "AXStaticText", title: "Done", handle: 1)] : []
            return (ComputerUseAXNode(role: "AXWindow", title: "Note", children: children, handle: 0), true, ComputerUseAXHandles())
        }
        let f = Self.fixture(system: system, recorder: recorder, allowed: [Self.notes])
        _ = await f.coordinator.perform(.init(action: .inspect, windowID: 1), sessionID: "s")
        let condition: ComputerUseCommand.WaitCondition = waitCase == .neverDisappears || waitCase == .disappears ? .disappear : .appear
        let wait = ComputerUseCommand(action: .wait, windowID: 1, query: "done", condition: condition, timeoutMS: 1000)
        let response = await f.coordinator.perform(wait, sessionID: "s")
        switch waitCase {
        case .appears:
            let json = try #require(Self.text(response))
            #expect(json.contains(#""ref":"e2""#) && json.contains(#""title":"Done""#))
            #expect(recorder.sleeps == [.milliseconds(250), .milliseconds(250)])
        case .disappears:
            #expect(try #require(Self.text(response)).contains(#""elements":[]"#))
            #expect(recorder.sleeps.isEmpty)
        case .windowCloses:
            #expect(response == .error("computer_window_not_found: No on-screen window 1. Call computer_apps again."))
            #expect(recorder.sleeps == [.milliseconds(250)])
        case .neverAppears, .neverDisappears:
            let verb = condition == .appear ? "appeared" : "disappeared"
            #expect(response == .error(#"computer_wait_timeout: Nothing matching "done" \#(verb) in window 1 within 1000 ms."#))
            #expect(recorder.sleeps.reduce(.zero, +) == .seconds(1))
            // The polls the agent never saw don't leave refs behind, nor do the inspect's survive.
            #expect(await f.coordinator.perform(.init(action: .click, windowID: 1, ref: "e1"), sessionID: "s")
                == .error("computer_stale: The element ref e1 is no longer valid. Call computer_inspect on window 1 again."))
            #expect(recorder.inputs.isEmpty)
        }
    }
}

/// The change check's warnings, spelled out so a reworded one fails the test.
private enum Warnings {
    static let noChange = "No change was observed in the window after this action; the app may have ignored it."
    static let drag = "Couldn't confirm the drag had an effect; inspect to verify."
}

/// Inputs, launches, sleeps, cancellation checks and ordered events seen by the fakes.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedInputs: [ComputerUseInput] = []
    private var recordedSleeps: [Duration] = []
    private var recordedChecks: [Bool] = []
    private var openCount = 0
    private var recordedEvents: [String] = []

    var inputs: [ComputerUseInput] { lock.withLock { recordedInputs } }
    var sleeps: [Duration] { lock.withLock { recordedSleeps } }
    var checks: [Bool] { lock.withLock { recordedChecks } }
    var opens: Int { lock.withLock { openCount } }
    var events: [String] { lock.withLock { recordedEvents } }

    func record(_ input: ComputerUseInput) { lock.withLock { recordedInputs.append(input) } }
    func recordSleep(_ duration: Duration) { lock.withLock { recordedSleeps.append(duration) } }
    func recordCheck(_ cancelled: Bool) { lock.withLock { recordedChecks.append(cancelled) } }
    func recordOpen() { lock.withLock { openCount += 1 } }
    func recordEvent(_ event: String) { lock.withLock { recordedEvents.append(event) } }
}

/// Holds each fake tree read until the test opens its window.
private final class TreeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var enteredIDs: Set<UInt32> = []
    private var opened: Set<UInt32> = []
    private var waiting: [UInt32: CheckedContinuation<Void, Never>] = [:]

    var entered: Set<UInt32> { lock.withLock { enteredIDs } }

    func enter(_ id: UInt32) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock {
                enteredIDs.insert(id)
                if opened.contains(id) { return true }
                waiting[id] = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open(_ id: UInt32) {
        let continuation = lock.withLock {
            opened.insert(id)
            return waiting.removeValue(forKey: id)
        }
        continuation?.resume()
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}
