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
            axTree: { _, _, _, _ in (saveTree, treeComplete ? nil : .timeLimit, ComputerUseAXHandles()) },
            perform: { input, _, _, _ in
                recorder?.record(input)
                recorder?.recordEvent("perform:\(Self.name(of: input))")
                return .ax
            },
            focusState: { _ in nil },
            elementState: { _, _ in nil },
            elementMatches: { _, _, _, _ in true },
            // The fake trees give each element one handle across reads.
            sameElement: { _, old, _, new in old == new },
            secondsSinceUserInput: { 60 },
            isFrontmost: { _ in false },
            resolveApp: { _, _ in notes },
            openApp: {
                recorder?.recordOpen()
                return $0
            }
        )
    }

    /// A prompt listing that has every one of `pids` showing a prompt.
    nonisolated private static func showing(_ pids: [Int32]) -> [Int32: ComputerUseCredentialPrompt.Listing] {
        Dictionary(uniqueKeysWithValues: pids.map { ($0, .showing) })
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
        sleep: (@Sendable (Duration) async -> Void)? = nil, cursor: ComputerUseCursor = .none,
        attention: @escaping @MainActor () -> Void = {}, now: @escaping @MainActor () -> Date = { Date() }
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
            sleep: sleep ?? { recorder.recordSleep($0) },
            cursor: cursor,
            attention: attention,
            now: now
        )
        for app in allowed {
            access.record(.allowForSession, for: app, session: "s")
        }
        return Fixture(coordinator: coordinator, access: access, lockURL: lockURL, calls: calls, recorder: recorder)
    }

    private nonisolated static func name(of input: ComputerUseInput) -> String {
        switch input {
        case .click: "click"
        case .type: "type"
        case .key: "key"
        case .scroll: "scroll"
        case .drag: "drag"
        case .pointerClick: "pointerClick"
        }
    }

    /// Logs "present", "cue:<case>" and "dismiss" into the recorder's events, next to the fake
    /// system's "perform:<input>"; a glide waits for `gate` window 1 when there is one.
    private static func cursor(_ recorder: Recorder, holdingGlidesAt gate: TreeGate? = nil) -> ComputerUseCursor {
        ComputerUseCursor(
            present: { _ in recorder.recordEvent("present") },
            perform: { cue in
                recorder.recordEvent("cue:\(Self.name(of: cue))")
                if case .glide = cue { await gate?.enter(1) }
            },
            dismiss: { recorder.recordEvent("dismiss") }
        )
    }

    private nonisolated static func name(of cue: ComputerUseCursorCue) -> String {
        switch cue {
        case .glide: "glide"
        case .jump: "jump"
        case .outline: "outline"
        case .hide: "hide"
        case .none: "none"
        }
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
        #expect(json.contains(#""truncated_by":"time_limit""#))
    }

    /// An Electron window that shows only groups at first contact is woken and read again until its
    /// web area has content; later reads of the app aren't.
    @Test func aWebWindowReadAsEmptyGroupsIsWokenAndReadAgainOnce() async throws {
        let recorder = Recorder()
        let reads = Counter()
        let woken = Counter()
        var system = Self.system()
        system.usesManualAccessibility = { _ in true }
        system.wakeWebContent = { _, _ in
            _ = woken.next()
            return true
        }
        // A web area that fills only on the third read.
        system.axTree = { _, _, _, _ in
            let read = reads.next()
            let field = ComputerUseAXNode(role: "AXTextField", handle: 2)
            let content = ComputerUseAXNode(role: read > 1 ? "AXWebArea" : "AXGroup", children: read > 2 ? [field] : [], handle: 1)
            return (ComputerUseAXNode(role: "AXWindow", children: [content], handle: 0), nil, ComputerUseAXHandles())
        }
        let f = Self.fixture(system: system, recorder: recorder, allowed: [Self.notes])
        let json = try #require(Self.text(await f.coordinator.perform(.init(action: .inspect, windowID: 1), sessionID: "s")))
        #expect(json.contains("AXTextField"))
        #expect(recorder.sleeps == [ComputerUseCoordinator.webContentPoll, ComputerUseCoordinator.webContentPoll])
        _ = await f.coordinator.perform(.init(action: .inspect, windowID: 1), sessionID: "s")
        #expect(reads.next() == 5)
        #expect(woken.next() == 2)
    }

    /// computer_open_app on an Electron app returns once its front window's web content shows.
    @Test func openingAWebAppWaitsForItsWebContent() async throws {
        let reads = Counter()
        let recorder = Recorder()
        var system = Self.system(recorder: recorder)
        system.usesManualAccessibility = { _ in true }
        system.axTree = { _, _, _, _ in
            let filled = reads.next() >= 3
            let area = ComputerUseAXNode(role: "AXWebArea", children: filled ? [ComputerUseAXNode(role: "AXTextField")] : [])
            return (ComputerUseAXNode(role: "AXWindow", children: [area]), nil, ComputerUseAXHandles())
        }
        let f = Self.fixture(system: system, recorder: recorder, allowed: [Self.notes])
        #expect(Self.text(await f.coordinator.perform(.init(action: .openApp, name: "Notes"), sessionID: "s")) != nil)
        #expect(reads.next() == 4)
        #expect(recorder.sleeps == [ComputerUseCoordinator.webContentPoll, ComputerUseCoordinator.webContentPoll])
    }

    /// A Chromium browser still showing no web area after AXManualAccessibility gets
    /// AXEnhancedUserInterface, which the turn's end turns off again.
    @Test func chromeGetsEnhancedUserInterfaceOnlyAsASecondTryAndUntilTheTurnEnds() async throws {
        let recorder = Recorder()
        let reads = Counter()
        let chrome = ComputerUseAppIdentity(name: "Google Chrome", bundleID: "com.google.Chrome", pid: 105)
        let window = ComputerUseWindow(windowID: 5, title: "Tab", frame: CGRect(x: 0, y: 0, width: 800, height: 600), app: chrome)
        var system = Self.system(windows: [5: window])
        system.wakeWebContent = { _, attribute in
            recorder.recordEvent("wake:\(attribute)")
            return attribute == "AXEnhancedUserInterface"
        }
        system.restoreWebContent = { _, attribute in recorder.recordEvent("restore:\(attribute)") }
        // The web content shows only once AXEnhancedUserInterface is set.
        system.axTree = { _, _, _, _ in
            let web = recorder.events.contains("wake:AXEnhancedUserInterface")
            let field = ComputerUseAXNode(role: "AXTextField", handle: 2)
            let content = ComputerUseAXNode(role: web ? "AXWebArea" : "AXGroup", children: web ? [field] : [], handle: 1)
            return (ComputerUseAXNode(role: "AXWindow", children: [content], handle: 0), nil, ComputerUseAXHandles())
        }
        let f = Self.fixture(system: system, recorder: recorder, allowed: [chrome])
        let json = try #require(Self.text(await f.coordinator.perform(.init(action: .inspect, windowID: 5), sessionID: "s")))
        #expect(json.contains("AXWebArea"))
        // No AXManualAccessibility for a Chromium browser: the wait comes first.
        #expect(recorder.events == ["wake:AXEnhancedUserInterface"])
        f.coordinator.turnEnded(sessionID: "s")
        try await eventually("restored") { recorder.events.last == "restore:AXEnhancedUserInterface" }
    }

    /// A session end while AXEnhancedUserInterface is being set finds nothing to restore yet, so
    /// the call that set it turns it off again itself.
    @Test func enhancedUserInterfaceSetAsTheSessionEndsIsTurnedOffAgain() async throws {
        let recorder = Recorder()
        let gate = Recorder()
        let chrome = ComputerUseAppIdentity(name: "Google Chrome", bundleID: "com.google.Chrome", pid: 105)
        let window = ComputerUseWindow(windowID: 5, title: "Tab", frame: CGRect(x: 0, y: 0, width: 800, height: 600), app: chrome)
        var system = Self.system(windows: [5: window])
        system.wakeWebContent = { _, attribute in
            guard attribute == "AXEnhancedUserInterface" else { return false }
            recorder.recordEvent("wake:\(attribute)")
            // Held until the session has ended.
            while gate.events.isEmpty { await Task.yield() }
            return true
        }
        system.restoreWebContent = { _, attribute in recorder.recordEvent("restore:\(attribute)") }
        system.axTree = { _, _, _, _ in
            (ComputerUseAXNode(role: "AXWindow", children: [ComputerUseAXNode(role: "AXGroup", handle: 1)], handle: 0),
             nil, ComputerUseAXHandles())
        }
        let f = Self.fixture(system: system, recorder: recorder, allowed: [chrome])
        let call = Task { await f.coordinator.perform(.init(action: .inspect, windowID: 5), sessionID: "s") }
        try await eventually("set in flight") { recorder.events == ["wake:AXEnhancedUserInterface"] }
        f.coordinator.sessionEnded(sessionID: "s")
        gate.recordEvent("open")
        _ = await call.value
        #expect(recorder.events == ["wake:AXEnhancedUserInterface", "restore:AXEnhancedUserInterface"])
    }

    /// A frame an app reports as NaN can't be written as JSON, and writing it would end the app:
    /// it reads as zeros.
    @Test func aNaNFrameFromTheAppReadsAsZeros() async throws {
        var system = Self.system()
        let tree = ComputerUseAXNode(role: "AXWindow", children: [
            ComputerUseAXNode(role: "AXLink", title: "Jef Raskin", frame: CGRect(x: CGFloat.nan, y: 10, width: .infinity, height: 20)),
        ])
        system.axTree = { _, _, _, _ in (tree, nil, ComputerUseAXHandles()) }
        let f = Self.fixture(system: system, allowed: [Self.notes])
        let json = try #require(Self.text(await f.coordinator.perform(.init(action: .inspect, windowID: 1), sessionID: "s")))
        #expect(json.contains(#""frame":{"height":20,"width":0,"x":0,"y":10}"#))
    }

    /// Only an element nothing of which shows carries `visible`.
    @Test func inspectMarksHiddenElements() async throws {
        var system = Self.system()
        let tree = ComputerUseAXNode(role: "AXWindow", frame: CGRect(x: 0, y: 0, width: 400, height: 300), children: [
            ComputerUseAXNode(role: "AXButton", title: "Shown", frame: CGRect(x: 10, y: 10, width: 50, height: 20)),
            ComputerUseAXNode(role: "AXButton", title: "Off", frame: CGRect(x: 10, y: 320, width: 50, height: 20)),
        ])
        system.axTree = { _, _, _, _ in (tree, nil, ComputerUseAXHandles()) }
        let f = Self.fixture(system: system)
        f.access.record(.allowForSession, for: Self.notes, session: "s")
        let json = try #require(Self.text(await f.coordinator.perform(.init(action: .inspect, windowID: 1), sessionID: "s")))
        let payload = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let elements = try #require(payload["elements"] as? [[String: Any]])
        #expect(elements.map { $0["visible"] as? Bool } == [nil, nil, false])
    }

    @Test func unansweredApprovalReturnsPendingAndKeepsTheCard() async {
        let f = Self.fixture(approvalWait: .milliseconds(200))
        let response = await f.coordinator.perform(.init(action: .screenshot, windowID: 1), sessionID: "s")
        #expect(response == .error("computer_approval_pending: Waiting for the user to approve Notes. Try again after they answer."))
        #expect(f.coordinator.pendingApprovals.count == 1)
    }

    /// A new card asks for the user's attention, and so does a later call waiting on it once
    /// 10 s passed; another card asks for its own.
    @Test func approvalCardsAskForAttentionAgainForLaterCalls() async {
        var asked = 0
        var clock = Date(timeIntervalSinceReferenceDate: 1000)
        let f = Self.fixture(approvalWait: .milliseconds(200), attention: { asked += 1 }, now: { clock })
        _ = await f.coordinator.perform(.init(action: .screenshot, windowID: 1), sessionID: "s")
        clock += 5
        _ = await f.coordinator.perform(.init(action: .inspect, windowID: 1), sessionID: "s")
        #expect(asked == 1)
        clock += 5
        _ = await f.coordinator.perform(.init(action: .inspect, windowID: 1), sessionID: "s")
        #expect(asked == 2)
        _ = await f.coordinator.perform(.init(action: .screenshot, windowID: 2), sessionID: "s")
        #expect(f.coordinator.pendingApprovals.count == 2)
        #expect(asked == 3)
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
        let tree = (root: ComputerUseAXNode(role: "AXWindow", title: "Inbox"), cut: ComputerUseReadCut?.none, handles: ComputerUseAXHandles())
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
            return (root: ComputerUseAXNode(role: "AXWindow", title: "Note"), cut: nil, handles: ComputerUseAXHandles())
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

    /// Running apps other than Alas with not one visible window: the Screen Recording prompt may
    /// be up, so the list carries a warning rather than reading as plain "no windows". Alas's own
    /// windows stay listed meanwhile, so they don't count.
    @Test(arguments: [(true, false, false), (false, false, true), (false, true, true)])
    func appsWarnWhenNoAppWindowIsVisible(notesVisible: Bool, alasVisible: Bool, warns: Bool) async throws {
        let notes = Self.windows[1]!
        let alas = Self.windows[4]!
        var system = Self.system()
        system.runningApps = {
            [(app: notes.app, windows: notesVisible ? [notes] : []), (app: alas.app, windows: alasVisible ? [alas] : [])]
        }
        let f = Self.fixture(system: system)
        let json = try #require(Self.text(await f.coordinator.perform(.init(action: .apps), sessionID: "s")))
        let payload = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect((payload["apps"] as? [Any])?.count == 2)
        #expect(payload["warning"] as? String == (warns
            ? "No app windows are visible. If macOS is showing a Screen Recording prompt, ask the user to answer it, then retry."
            : nil))
    }

    /// A blocked menu-bar app is listed, so computer_apps shows why computer_open_app refuses it;
    /// other menu-bar apps stay out.
    @Test func menuBarAppsAreListedOnlyWhenBlocked() async throws {
        var system = Self.system()
        system.accessoryApps = {
            [ComputerUseAppIdentity(name: "1Password", bundleID: "com.1password.1password", pid: 201),
             ComputerUseAppIdentity(name: "Stream Deck", bundleID: "com.elgato.StreamDeck", pid: 202)]
        }
        let f = Self.fixture(system: system)
        let json = try #require(Self.text(await f.coordinator.perform(.init(action: .apps), sessionID: "s")))
        let apps = try #require((try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])?["apps"] as? [[String: Any]])
        let names = apps.compactMap { $0["name"] as? String }
        #expect(names == ["1Password", "Alas Dev", "Keychain Access", "Mail", "Notes"])
        let blocked = try #require(apps.first)
        #expect(blocked["approval"] as? String == "blocked")
        #expect((blocked["windows"] as? [Any])?.isEmpty == true)
    }

    /// A window none of which is on a display (an AeroSpace workspace, another Space) says so.
    @Test func appsMarkWindowsOffEveryDisplay() async throws {
        var system = Self.system()
        // Notes' centre (200, 150) is off the display, with under a quarter of it on; Mail's
        // centre (260, 210) is on.
        system.displays = { [CGRect(x: 210, y: 160, width: 500, height: 500)] }
        let f = Self.fixture(system: system)
        let json = try #require(Self.text(await f.coordinator.perform(.init(action: .apps), sessionID: "s")))
        let apps = try #require((try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])?["apps"] as? [[String: Any]])
        let windows = Dictionary(uniqueKeysWithValues: apps.compactMap { app in
            (app["windows"] as? [[String: Any]])?.first.map { (app["name"] as? String ?? "", $0) }
        })
        #expect(windows["Notes"]?["off_screen"] as? Bool == true)
        #expect(windows["Mail"]?["off_screen"] == nil)
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
            return (tree, cut ? .timeLimit : nil, ComputerUseAXHandles())
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
        // The user isn't in Notes (nothing is frontmost in the fake): the message names the Mac.
        (.userActive, false, "computer_user_active: You're using the Mac right now. Try again in a moment."),
        (.staleDropElement, true,
         "computer_stale: The element ref e1 is no longer valid. Call computer_inspect on window 1 again."),
        (.staleElement, true,
         "computer_stale: The element ref e2 is no longer valid. Call computer_inspect on window 1 again."),
        (.userTookOverDrag, true,
         "computer_user_active: You started using the Mac, so the drag was cancelled mid-way; nothing was dropped."),
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
        system.isFrontmost = { $0 == 101 }
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

    /// While a system password prompt shows in an app, nothing of it is seen or driven, and no
    /// card asks for it; computer_apps lists the app without its windows.
    @Test(arguments: [
        ComputerUseCommand(action: .screenshot, windowID: 1), .init(action: .inspect, windowID: 1),
        .init(action: .key, windowID: 1, keys: "return"), .init(action: .type, windowID: 1, text: "hunter2"),
    ])
    func aCredentialPromptBlocksTheWholeApp(_ command: ComputerUseCommand) async throws {
        let recorder = Recorder()
        let notes = Self.notes
        var system = Self.system(recorder: recorder)
        let mail = Self.mail
        system.credentialPrompts = { pids in
            var listings: [Int32: ComputerUseCredentialPrompt.Listing] = [:]
            if pids.contains(notes.pid) { listings[notes.pid] = .showing }
            if pids.contains(mail.pid) { listings[mail.pid] = .unchecked }
            return listings
        }
        let f = Self.fixture(system: system, recorder: recorder)
        let response = await f.coordinator.perform(command, sessionID: "s")
        #expect(response == .error("computer_blocked: A system password prompt is showing in Notes; ask the user to answer it."))
        #expect(recorder.inputs.isEmpty)
        #expect(f.coordinator.pendingApprovals.isEmpty)

        let json = try #require(Self.text(await f.coordinator.perform(.init(action: .apps), sessionID: "s")))
        let apps = try #require((try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])?["apps"] as? [[String: Any]])
        let listed = try #require(apps.first { $0["name"] as? String == "Notes" })
        #expect(listed["credential_prompt"] as? Bool == true)
        #expect((listed["windows"] as? [Any])?.isEmpty == true)
        // Past the listing's probe budget: its windows are withheld, but no prompt is claimed.
        let unchecked = try #require(apps.first { $0["name"] as? String == "Mail" })
        #expect(unchecked["credential_prompt"] as? String == "unchecked")
        #expect((unchecked["windows"] as? [Any])?.isEmpty == true)
    }

    /// A click that brings the prompt up went through, but the window's elements and refs are withheld.
    @Test func anInputThatBringsUpACredentialPromptWithholdsTheWindow() async throws {
        let recorder = Recorder()
        var system = Self.system(recorder: recorder)
        system.credentialPrompts = { [recorder] pids in recorder.inputs.isEmpty ? [:] : Self.showing(pids) }
        let f = Self.fixture(system: system, recorder: recorder, allowed: [Self.notes])
        _ = await f.coordinator.perform(.init(action: .inspect, windowID: 1), sessionID: "s")
        let json = try #require(Self.text(await f.coordinator.perform(.init(action: .click, windowID: 1, ref: "e2"), sessionID: "s")))
        let payload = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(payload["delivery"] as? String == "ax")
        #expect(payload["credential_prompt"] as? Bool == true)
        #expect((payload["elements"] as? [Any])?.isEmpty == true)
        let again = await f.coordinator.perform(.init(action: .click, windowID: 1, ref: "e2"), sessionID: "s")
        #expect(again == .error("computer_blocked: A system password prompt is showing in Notes; ask the user to answer it."))
        #expect(recorder.inputs.count == 1)
    }

    /// An Electron press that changed nothing is retried as a pointer click; when that click brings
    /// the prompt up, neither the retry's read nor the screenshot comes back.
    @Test func aPointerRetryThatBringsUpACredentialPromptWithholdsTheWindow() async throws {
        let recorder = Recorder()
        var system = Self.system(recorder: recorder)
        system.usesManualAccessibility = { _ in true }
        system.perform = { input, _, _, _ in
            recorder.record(input)
            if case .pointerClick = input { return .background }
            return .ax
        }
        system.credentialPrompts = { [recorder] pids in
            recorder.inputs.contains { if case .pointerClick = $0 { true } else { false } } ? Self.showing(pids) : [:]
        }
        let f = Self.fixture(system: system, recorder: recorder, allowed: [Self.notes])
        _ = await f.coordinator.perform(.init(action: .inspect, windowID: 1), sessionID: "s")
        let click = ComputerUseCommand(action: .click, windowID: 1, ref: "e2", includeScreenshot: true)
        let json = try #require(Self.text(await f.coordinator.perform(click, sessionID: "s")))
        let payload = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(payload["retried"] as? String == "pointer")
        #expect(payload["credential_prompt"] as? Bool == true)
        #expect((payload["elements"] as? [Any])?.isEmpty == true)
        #expect(payload["image"] == nil)
        #expect(await f.coordinator.perform(.init(action: .click, windowID: 1, ref: "e2"), sessionID: "s")
            == .error("computer_blocked: A system password prompt is showing in Notes; ask the user to answer it."))
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
    /// element in its place. `filteredReadShiftedALookalikeIn`: the tree shifted, and another
    /// element with the same role and title now sits where the shown one was.
    enum RefExpiry: CaseIterable {
        case turnEnd, reinspectWithoutTheNode, elementChanged, filteredReadRetitledTheNode, filteredReadShiftedALookalikeIn
    }

    @Test(arguments: RefExpiry.allCases)
    func refsExpireWithTheTurnAndOnReinspect(_ expiry: RefExpiry) async throws {
        let recorder = Recorder()
        let reads = Counter()
        let saveTree = Self.saveTree
        var system = Self.system(recorder: recorder)
        let retitled = ComputerUseAXNode(
            role: "AXWindow", title: "Note", children: [ComputerUseAXNode(role: "AXButton", title: "Delete", handle: 1)], handle: 0)
        let shifted = ComputerUseAXNode(role: "AXWindow", title: "Note", children: [
            ComputerUseAXNode(role: "AXButton", title: "Save", handle: 2), ComputerUseAXNode(role: "AXButton", title: "Save", handle: 1),
        ], handle: 0)
        // Only the first read still has the Save button.
        system.axTree = { _, _, _, _ in
            guard reads.next() > 1 else { return (saveTree, nil, ComputerUseAXHandles()) }
            let later = switch expiry {
            case .filteredReadRetitledTheNode: retitled
            case .filteredReadShiftedALookalikeIn: shifted
            case .turnEnd, .reinspectWithoutTheNode, .elementChanged: ComputerUseAXNode(role: "AXWindow", title: "Note", handle: 0)
            }
            return (later, nil, ComputerUseAXHandles())
        }
        // The element behind the handle still exists, but now reads as another button.
        system.elementMatches = { _, handle, role, title in
            switch expiry {
            case .elementChanged: false
            // The live element is the retitled one, so only the ref's expected identity can catch it.
            case .filteredReadRetitledTheNode: handle == 1 && role == "AXButton" && title == "Delete"
            // Both buttons read as Save, so only the element's identity can tell them apart.
            case .filteredReadShiftedALookalikeIn: role == "AXButton" && title == "Save"
            case .turnEnd, .reinspectWithoutTheNode: handle == 1 && role == "AXButton" && title == "Save"
            }
        }
        let f = Self.fixture(system: system, recorder: recorder, allowed: [Self.notes])
        _ = await f.coordinator.perform(.init(action: .inspect, windowID: 1, query: "Save"), sessionID: "s")
        switch expiry {
        case .turnEnd: f.coordinator.turnEnded(sessionID: "s")
        case .reinspectWithoutTheNode: _ = await f.coordinator.perform(.init(action: .inspect, windowID: 1, query: "Save"), sessionID: "s")
        case .filteredReadRetitledTheNode, .filteredReadShiftedALookalikeIn:
            _ = await f.coordinator.perform(.init(action: .inspect, windowID: 1, query: "Note"), sessionID: "s")
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

    /// `mappedLate`: the end window shows the drop only on a re-read, as Finder does.
    enum CrossWindowDrop: CaseIterable { case mapped, mappedLate, outOfBounds, staleRef, otherApp }

    /// The drop end resolves in the end window: its screenshot, its frame and its refs. The end
    /// window is read back too, so a drop that changed only it isn't reported as no change, nor
    /// one that shows a moment later. Another app's window is refused before any card or input.
    @Test(arguments: CrossWindowDrop.allCases)
    func dragIntoAnotherWindowUsesThatWindow(_ drop: CrossWindowDrop) async throws {
        let recorder = Recorder()
        let endReads = Counter()
        var windows = Self.windows
        windows[5] = ComputerUseWindow(windowID: 5, title: "Other", frame: CGRect(x: 10, y: 10, width: 500, height: 400), app: Self.notes)
        var system = Self.system(windows: windows, recorder: recorder)
        let saveTree = Self.saveTree
        // The end window's second read (the one after the drop) shows a new element; a late
        // drop shows it from the third (the first re-read) on.
        system.axTree = { window, _, _, _ in
            var tree = saveTree
            if window.windowID == 5 {
                let read = endReads.next()
                if drop == .mappedLate ? read >= 3 : read == 2 { tree.children.append(ComputerUseAXNode(role: "AXImage", handle: 2)) }
            }
            return (tree, nil, ComputerUseAXHandles())
        }
        system.perform = { input, _, _, _ in
            recorder.record(input)
            return .activation
        }
        let f = Self.fixture(system: system, recorder: recorder, allowed: [Self.notes])
        _ = await f.coordinator.perform(.init(action: .screenshot, windowID: 1), sessionID: "s")
        _ = await f.coordinator.perform(.init(action: .screenshot, windowID: 5), sessionID: "s")
        let drag: ComputerUseCommand = switch drop {
        case .mapped, .mappedLate: .init(action: .drag, windowID: 1, x: 10, y: 10, toWindowID: 5, toX: 100, toY: 100)
        case .outOfBounds: .init(action: .drag, windowID: 1, x: 10, y: 10, toWindowID: 5, toX: 2000, toY: 2000)
        // Window 5 was never inspected, so e1 there is unknown even though window 1 has none either.
        case .staleRef: .init(action: .drag, windowID: 1, x: 10, y: 10, toWindowID: 5, toRef: "e1")
        case .otherApp: .init(action: .drag, windowID: 1, x: 10, y: 10, toWindowID: 2, toX: 100, toY: 100)
        }
        let response = await f.coordinator.perform(drag, sessionID: "s")
        switch drop {
        case .mapped, .mappedLate:
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
            #expect(recorder.sleeps.contains(ComputerUseCoordinator.dragConfirmPoll) == (drop == .mappedLate))
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

    /// A drag always goes with the app in front, so like direct delivery it waits for a user who
    /// is active in any app, then gives up.
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
            #expect(response == .error("computer_user_active: You're using the Mac right now. Try again in a moment."))
            #expect(recorder.inputs.isEmpty && recorder.sleeps.reduce(.zero, +) == .seconds(10))
        }
    }

    /// A drag that grabbed the window itself moved it: that is a failure, not a drop.
    @Test(arguments: [(CGFloat(40), true), (CGFloat(1), false)])
    func dragThatMovedTheWindowFails(offset: CGFloat, fails: Bool) async throws {
        let recorder = Recorder()
        var system = Self.system(recorder: recorder)
        let windows = Self.windows
        system.window = { id in
            guard var window = windows[id] else { return nil }
            if !recorder.inputs.isEmpty { window.frame = window.frame.offsetBy(dx: offset, dy: 0) }
            return window
        }
        system.perform = { input, _, _, _ in
            recorder.record(input)
            return .activation
        }
        let f = Self.fixture(system: system, recorder: recorder, allowed: [Self.notes])
        _ = await f.coordinator.perform(.init(action: .inspect, windowID: 1), sessionID: "s")
        let response = await f.coordinator.perform(.init(action: .drag, windowID: 1, ref: "e2", toRef: "e1"), sessionID: "s")
        #expect(recorder.inputs.count == 1)
        let failure = AlasCLIResponse.error(
            "computer_action_failed: The drag moved the window instead of an item; nothing was dropped.")
        #expect((response == failure) == fails)
    }

    /// An AX press in an Electron app may only focus the element: a click that changed nothing
    /// there is clicked once more with the pointer. Elsewhere, after a change, and on a toggle a
    /// second press could undo, it stands.
    /// How much of the window the reads around the press see.
    enum PostRead: Sendable { case full, depthLimited, queryFiltered }

    @Test(arguments: [
        (true, false, "AXButton", .full, true), (true, true, "AXButton", .full, false),
        (false, false, "AXButton", .full, false), (true, false, "AXCheckBox", .full, false),
        // A read that leaves elements out can't tell the press changed nothing.
        (true, false, "AXButton", .depthLimited, false), (true, false, "AXButton", .queryFiltered, false),
    ] as [(Bool, Bool, String, PostRead, Bool)])
    func electronClickThatChangedNothingIsRetriedWithThePointer(
        manualAccessibility: Bool, changed: Bool, role: String, postRead: PostRead, retries: Bool
    ) async throws {
        let recorder = Recorder()
        let reads = Counter()
        var saveTree = Self.saveTree
        saveTree.children[0].role = role
        // Its web content is built already.
        saveTree.children.append(ComputerUseAXNode(role: "AXWebArea", children: [ComputerUseAXNode(role: "AXGroup")]))
        // A group whose children the read didn't go deep enough to see.
        if postRead == .depthLimited { saveTree.children.append(ComputerUseAXNode(role: "AXGroup", childrenUnread: true)) }
        var system = Self.system(recorder: recorder)
        system.usesManualAccessibility = { $0 == 101 && manualAccessibility }
        // Read 1 is the inspect, 2 the window before the click, 3 the one after it.
        system.axTree = { [saveTree] _, _, _, _ in
            var tree = saveTree
            if changed, reads.next() >= 3 { tree.children.append(ComputerUseAXNode(role: "AXSheet", handle: 2)) }
            return (tree, nil, ComputerUseAXHandles())
        }
        system.perform = { input, _, _, _ in
            recorder.record(input)
            if case .pointerClick = input { return .background }
            return .ax
        }
        let f = Self.fixture(system: system, recorder: recorder, allowed: [Self.notes])
        _ = await f.coordinator.perform(.init(action: .inspect, windowID: 1), sessionID: "s")
        let click = ComputerUseCommand(action: .click, windowID: 1, query: postRead == .queryFiltered ? "save" : nil, ref: "e2")
        let json = try #require(Self.text(await f.coordinator.perform(click, sessionID: "s")))
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

    /// A press the app didn't answer in time (a modal panel it opened) counts as delivered with a
    /// warning, and is never pressed again, also where an Electron press that changed nothing would be.
    @Test func anUnconfirmedPressIsDeliveredWithAWarningAndNotRetried() async throws {
        let recorder = Recorder()
        var system = Self.system(recorder: recorder)
        system.usesManualAccessibility = { _ in true }
        system.perform = { input, _, _, _ in
            recorder.record(input)
            return ComputerUseDelivered(delivery: .ax, warning: "The app didn't answer in time.")
        }
        let f = Self.fixture(system: system, recorder: recorder, allowed: [Self.notes])
        _ = await f.coordinator.perform(.init(action: .inspect, windowID: 1), sessionID: "s")
        let json = try #require(Self.text(await f.coordinator.perform(.init(action: .click, windowID: 1, ref: "e2"), sessionID: "s")))
        let payload = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(payload["delivery"] as? String == "ax" && payload["retried"] == nil)
        #expect((payload["warning"] as? String)?.hasPrefix("The app didn't answer in time.") == true)
        #expect(recorder.inputs.count == 1)
    }

    /// The first press was delivered either way: a retry the user's return refuses leaves its
    /// result as it was, with the reason.
    @Test func failedPointerRetryKeepsTheFirstResult() async throws {
        let recorder = Recorder()
        var system = Self.system(recorder: recorder)
        system.usesManualAccessibility = { _ in true }
        system.isFrontmost = { $0 == 101 }
        // Idle until the first press, active from then on.
        let presses = Recorder()
        system.secondsSinceUserInput = { presses.inputs.isEmpty ? 60 : 0.5 }
        system.perform = { input, _, _, _ in
            presses.record(input)
            recorder.record(input)
            return .ax
        }
        let f = Self.fixture(system: system, recorder: recorder, allowed: [Self.notes])
        _ = await f.coordinator.perform(.init(action: .inspect, windowID: 1), sessionID: "s")
        let json = try #require(Self.text(await f.coordinator.perform(.init(action: .click, windowID: 1, ref: "e2"), sessionID: "s")))
        let payload = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(recorder.inputs.count == 1)
        #expect(payload["delivery"] as? String == "ax" && payload["warning"] as? String == Warnings.noChange)
        #expect(payload["retried"] == nil
            && payload["retry_error"] as? String == "computer_user_active: The user is using Notes right now. Try again in a moment.")
    }

    /// A pointer retry that left the window looking the same, or whose read can't tell, is no
    /// success: the no-change warning stays next to `retried`.
    @Test(arguments: [true, false])
    func pointerRetryThatShowsNoChangeKeepsTheWarning(retryReadTruncated: Bool) async throws {
        let recorder = Recorder()
        let reads = Counter()
        var system = Self.system(recorder: recorder)
        system.usesManualAccessibility = { _ in true }
        // Read 1 is the inspect, 2 the window before the press, 3 after it, 4 after the retry.
        var saveTree = Self.saveTree
        // Its web content is built already.
        saveTree.children.append(ComputerUseAXNode(role: "AXWebArea", children: [ComputerUseAXNode(role: "AXGroup")]))
        system.axTree = { [saveTree] _, _, _, _ in (saveTree, retryReadTruncated && reads.next() >= 4 ? .timeLimit : nil, ComputerUseAXHandles()) }
        // Otherwise only the focus moves with the pointer click.
        system.focusState = { _ in
            !retryReadTruncated && recorder.inputs.count > 1 ? .init(role: "AXButton", title: "Save") : nil
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
        #expect(recorder.inputs.count == 2)
        #expect(payload["retried"] as? String == "pointer" && payload["warning"] as? String == Warnings.noChange)
    }

    /// An app still opening what the input showed (a sheet) may not answer the first read back.
    @Test func postActionReadTheAppDidNotAnswerIsRetriedOnce() async throws {
        let recorder = Recorder()
        let reads = Counter()
        var system = Self.system(recorder: recorder)
        // Read 1 is the inspect, 2 the window before the press, 3 the first read after it.
        let saveTree = Self.saveTree
        system.axTree = { _, _, _, _ in
            if reads.next() == 3 { throw ComputerUseSystemError.appNotResponding("Notes") }
            return (saveTree, nil, ComputerUseAXHandles())
        }
        let f = Self.fixture(system: system, recorder: recorder, allowed: [Self.notes])
        _ = await f.coordinator.perform(.init(action: .inspect, windowID: 1), sessionID: "s")
        let json = try #require(Self.text(await f.coordinator.perform(.init(action: .click, windowID: 1, ref: "e2"), sessionID: "s")))
        let payload = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(payload["post_state_error"] == nil)
        #expect((payload["elements"] as? [[String: Any]])?.isEmpty == false)
        #expect(recorder.sleeps.contains(ComputerUseCoordinator.postReadRetryDelay))
    }

    @Test func actionWaitsForUserIdleThenGivesUp() async throws {
        let recorder = Recorder()
        var system = Self.system(recorder: recorder)
        system.isFrontmost = { $0 == 101 }
        system.secondsSinceUserInput = { 0.5 }
        let f = Self.fixture(system: system, recorder: recorder, allowed: [Self.notes])
        let response = await f.coordinator.perform(.init(action: .key, windowID: 1, keys: "cmd+s"), sessionID: "s")
        #expect(response == .error("computer_user_active: The user is using Notes right now. Try again in a moment."))
        #expect(recorder.sleeps.reduce(.zero, +) == .seconds(10))
        #expect(recorder.inputs.isEmpty)
    }

    /// Direct delivery would take the screen: it waits for a user active in another app too, and
    /// goes once they stop.
    @Test(arguments: [false, true])
    func directDeliveryWaitsForTheUserWhereverTheyAre(userStops: Bool) async throws {
        let recorder = Recorder()
        let polls = Counter()
        var system = Self.system(recorder: recorder)
        system.secondsSinceUserInput = { userStops && polls.next() > 3 ? 60 : 0.5 }
        let f = Self.fixture(system: system, recorder: recorder, allowed: [Self.notes])
        let response = await f.coordinator.perform(.init(action: .key, windowID: 1, keys: "cmd+s", delivery: .direct), sessionID: "s")
        if userStops {
            #expect(Self.text(response) != nil && recorder.inputs.count == 1)
            #expect(recorder.sleeps.prefix(3) == [.milliseconds(100), .milliseconds(100), .milliseconds(100)])
        } else {
            #expect(response == .error("computer_user_active: You're using the Mac right now. Try again in a moment."))
            #expect(recorder.sleeps.reduce(.zero, +) == .seconds(10) && recorder.inputs.isEmpty)
        }
    }

    @Test func turnEndDuringTheTakeoverWaitSendsNothing() async throws {
        let gate = TreeGate()
        let recorder = Recorder()
        let polls = Counter()
        var system = Self.system(recorder: recorder)
        system.isFrontmost = { $0 == 101 }
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
        system.isFrontmost = { $0 == 101 }
        system.secondsSinceUserInput = { polls.next() == 1 ? 0.5 : 60 }
        let f = Self.fixture(system: system, recorder: recorder, allowed: [Self.notes])
        _ = await f.coordinator.perform(.init(action: .screenshot, windowID: 1), sessionID: "s")
        let response = await f.coordinator.perform(.init(action: .click, windowID: 1, x: 200, y: 100), sessionID: "s")
        #expect(response == .error("computer_out_of_bounds: Window 1 moved or resized since its screenshot. Call computer_screenshot again."))
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
            return (saveTree, nil, ComputerUseAXHandles())
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
            return (saveTree, nil, ComputerUseAXHandles())
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

    // MARK: - Cursor

    /// The glide comes before the takeover wait, so the wait and the ref re-check stay the last
    /// steps before the input.
    @Test func aCoordinateClickGlidesBeforeTheTakeoverWaitAndTheInput() async throws {
        let recorder = Recorder()
        let polls = Counter()
        var system = Self.system(recorder: recorder)
        // The user is busy in Notes at the first poll, then idle.
        system.isFrontmost = { $0 == 101 }
        system.secondsSinceUserInput = { polls.next() == 1 ? 0.5 : 60 }
        let f = Self.fixture(
            system: system, recorder: recorder, allowed: [Self.notes], sleep: { _ in recorder.recordEvent("sleep") },
            cursor: Self.cursor(recorder))
        _ = await f.coordinator.perform(.init(action: .screenshot, windowID: 1), sessionID: "s")
        #expect(Self.text(await f.coordinator.perform(.init(action: .click, windowID: 1, x: 200, y: 100), sessionID: "s")) != nil)
        // The takeover poll, the input, then the post-action settle.
        #expect(recorder.events == ["present", "cue:glide", "sleep", "perform:click", "sleep"])
    }

    /// The element's frame is kept relative to its window, so the cue follows a window that moved
    /// between the inspect and the click.
    /// It also goes to the part of the element its scroll area shows, as an event click would.
    @Test func aClickByRefGlidesToTheVisiblePartOfTheElementWhereItsWindowIsNow() async throws {
        let recorder = Recorder()
        let lookups = Counter()
        let original = ComputerUseWindow(windowID: 1, title: "Note", frame: CGRect(x: 100, y: 50, width: 400, height: 300), app: Self.notes)
        var moved = original
        moved.frame.origin = CGPoint(x: 300, y: 150)
        // The scroll area shows only the button's top half.
        let tree = ComputerUseAXNode(role: "AXWindow", title: "Note", children: [
            ComputerUseAXNode(role: "AXScrollArea", frame: CGRect(x: 100, y: 50, width: 400, height: 20), children: [
                ComputerUseAXNode(role: "AXButton", title: "Save", frame: CGRect(x: 110, y: 60, width: 50, height: 20), handle: 1),
            ], handle: 2),
        ], handle: 0)
        var system = Self.system(recorder: recorder)
        // The inspect resolves the original frame; the window has moved by the click.
        system.window = { [moved] _ in lookups.next() <= 1 ? original : moved }
        system.axTree = { _, _, _, _ in (tree, nil, ComputerUseAXHandles()) }
        let cursor = ComputerUseCursor(present: { _ in }, perform: { recorder.recordEvent("\($0)") }, dismiss: {})
        let f = Self.fixture(system: system, recorder: recorder, allowed: [Self.notes], cursor: cursor)
        _ = await f.coordinator.perform(.init(action: .inspect, windowID: 1, query: "Save"), sessionID: "s")
        #expect(Self.text(await f.coordinator.perform(.init(action: .click, windowID: 1, ref: "e3"), sessionID: "s")) != nil)
        let expected = ComputerUseCursorCue.glide(
            to: CGPoint(x: 335, y: 165), outline: CGRect(x: 310, y: 160, width: 50, height: 20), click: true)
        #expect(recorder.events.first == "\(expected)")
    }

    @Test func aStopDuringTheGlideDeliversNothing() async throws {
        let recorder = Recorder()
        let gate = TreeGate()
        let f = Self.fixture(
            system: Self.system(recorder: recorder), recorder: recorder, allowed: [Self.notes],
            cursor: Self.cursor(recorder, holdingGlidesAt: gate))
        _ = await f.coordinator.perform(.init(action: .screenshot, windowID: 1), sessionID: "s")
        let call = Task { await f.coordinator.perform(.init(action: .click, windowID: 1, x: 200, y: 100), sessionID: "s") }
        try await eventually("gliding") { gate.entered == [1] }
        await f.coordinator.stop(sessionID: "s")
        gate.open(1)
        #expect(await call.value == .error(ComputerUseCoordinator.Message.stopped))
        #expect(!recorder.events.contains { $0.hasPrefix("perform:") })
    }

    @Test(arguments: ["stop", "turnEnded", "sessionEnded"])
    func endingTheSessionDismissesTheCursor(end: String) async throws {
        let recorder = Recorder()
        let f = Self.fixture(
            system: Self.system(recorder: recorder), recorder: recorder, allowed: [Self.notes], cursor: Self.cursor(recorder))
        _ = await f.coordinator.perform(.init(action: .screenshot, windowID: 1), sessionID: "s")
        _ = await f.coordinator.perform(.init(action: .click, windowID: 1, x: 200, y: 100), sessionID: "s")
        // Another session ending leaves the cursor up.
        f.coordinator.sessionEnded(sessionID: "other")
        #expect(recorder.events.last == "perform:click")
        switch end {
        case "stop": await f.coordinator.stop(sessionID: "s")
        case "turnEnded": f.coordinator.turnEnded(sessionID: "s")
        default: f.coordinator.sessionEnded(sessionID: "s")
        }
        #expect(recorder.events.last == "dismiss")
    }

    @Test func aDragHidesTheCursorAndParksItAtTheDrop() async throws {
        let recorder = Recorder()
        let f = Self.fixture(
            system: Self.system(recorder: recorder), recorder: recorder, allowed: [Self.notes], cursor: Self.cursor(recorder))
        _ = await f.coordinator.perform(.init(action: .screenshot, windowID: 1), sessionID: "s")
        let drag = ComputerUseCommand(action: .drag, windowID: 1, x: 10, y: 10, toX: 100, toY: 100)
        #expect(Self.text(await f.coordinator.perform(drag, sessionID: "s")) != nil)
        let events = recorder.events
        let hide = try #require(events.firstIndex(of: "cue:hide"))
        let delivered = try #require(events.firstIndex(of: "perform:drag"))
        let jump = try #require(events.firstIndex(of: "cue:jump"))
        #expect(hide < delivered && delivered < jump)
    }

    @Test(arguments: Interruption.allCases)
    func aDragStoppedMidDeliveryDoesNotParkTheCursor(_ interruption: Interruption) async throws {
        let recorder = Recorder()
        let gate = TreeGate()
        var system = Self.system(recorder: recorder)
        system.perform = { input, _, _, _ in
            recorder.record(input)
            recorder.recordEvent("perform:drag")
            await gate.enter(1)
            return .activation
        }
        let f = Self.fixture(system: system, recorder: recorder, allowed: [Self.notes], cursor: Self.cursor(recorder))
        _ = await f.coordinator.perform(.init(action: .screenshot, windowID: 1), sessionID: "s")
        let drag = ComputerUseCommand(action: .drag, windowID: 1, x: 10, y: 10, toX: 100, toY: 100)
        let call = Task { await f.coordinator.perform(drag, sessionID: "s") }
        try await eventually("dragging") { gate.entered == [1] }
        switch interruption {
        case .stop: await f.coordinator.stop(sessionID: "s")
        case .turnEnd: f.coordinator.turnEnded(sessionID: "s")
        }
        gate.open(1)
        _ = await call.value
        #expect(recorder.events.suffix(2) == ["perform:drag", "dismiss"])
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

    enum WaitCase: CaseIterable { case appears, neverAppears, disappears, neverDisappears, disappearsFromPartialRead, windowCloses }

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
            case .neverAppears, .disappears, .disappearsFromPartialRead, .windowCloses: false
            case .neverDisappears: read > 1
            }
            let children = done ? [ComputerUseAXNode(role: "AXStaticText", title: "Done", handle: 1)] : []
            // A walk that ran out of budget may have missed "Done".
            let cut: ComputerUseReadCut? = waitCase == .disappearsFromPartialRead ? .nodeBudget : nil
            return (ComputerUseAXNode(role: "AXWindow", title: "Note", children: children, handle: 0), cut, ComputerUseAXHandles())
        }
        let f = Self.fixture(system: system, recorder: recorder, allowed: [Self.notes])
        _ = await f.coordinator.perform(.init(action: .inspect, windowID: 1), sessionID: "s")
        let condition: ComputerUseCommand.WaitCondition =
            [.neverDisappears, .disappears, .disappearsFromPartialRead].contains(waitCase) ? .disappear : .appear
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
        case .neverAppears, .neverDisappears, .disappearsFromPartialRead:
            let verb = condition == .appear ? "appeared" : "disappeared"
            #expect(response == .error(waitCase == .disappearsFromPartialRead
                ? #"computer_wait_timeout: Couldn't confirm that "done" disappeared from window 1 within 1000 ms: "#
                    + "the window's accessibility tree couldn't be read completely, so it may still be there."
                : #"computer_wait_timeout: Nothing matching "done" \#(verb) in window 1 within 1000 ms."#))
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
