import Foundation
import Testing
@testable import Alas

@MainActor
struct ComputerUseCoordinatorTests {
    private static let notes = ComputerUseAppIdentity(name: "Notes", bundleID: "com.apple.Notes", pid: 101)
    private static let mail = ComputerUseAppIdentity(name: "Mail", bundleID: "com.apple.mail", pid: 102)
    private static let keychain = ComputerUseAppIdentity(name: "Keychain Access", bundleID: "com.apple.keychainaccess", pid: 103)
    private static let windows: [UInt32: ComputerUseWindow] = [
        1: ComputerUseWindow(windowID: 1, title: "Note", frame: CGRect(x: 0, y: 0, width: 400, height: 300), app: notes),
        2: ComputerUseWindow(windowID: 2, title: "Inbox", frame: CGRect(x: 10, y: 10, width: 500, height: 400), app: mail),
        3: ComputerUseWindow(windowID: 3, title: "Login", frame: CGRect(x: 20, y: 20, width: 600, height: 500), app: keychain),
    ]

    private static func system(windows: [UInt32: ComputerUseWindow] = windows, treeComplete: Bool = true) -> ComputerUseSystem {
        ComputerUseSystem(
            runningApps: { windows.values.map { (app: $0.app, windows: [$0]) } },
            window: { windows[$0] },
            screenshot: { _ in ComputerUseScreenshot(png: Data([0x89]), pixelSize: CGSize(width: 800, height: 600), scale: 2) },
            axTree: { _, _, _ in
                (ComputerUseAXNode(role: "AXWindow", title: "Note", children: [ComputerUseAXNode(role: "AXButton", title: "Save")]), treeComplete)
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
    }

    /// The wait is long by default so a slow runner never times out an approval a test answers.
    private static func fixture(system: ComputerUseSystem = system(), approvalWait: Duration = .seconds(60)) -> Fixture {
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
            approvalWait: approvalWait
        )
        return Fixture(coordinator: coordinator, access: access, lockURL: lockURL, calls: calls)
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
        let tree = (root: ComputerUseAXNode(role: "AXWindow", title: "Inbox"), complete: true)
        let windows = Self.windows
        let system = ComputerUseSystem(
            runningApps: { [] },
            window: { windows[$0] },
            screenshot: { _ in throw ComputerUseSystemError.captureFailed("unused") },
            axTree: { window, _, _ in
                await gate.enter(window.windowID)
                if window.windowID == 1 { throw ComputerUseSystemError.captureFailed("Notes failed") }
                return tree
            }
        )
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
        let windows = Self.windows
        let system = ComputerUseSystem(
            runningApps: { [] },
            window: { windows[$0] },
            screenshot: { _ in throw ComputerUseSystemError.captureFailed("unused") },
            axTree: { window, _, _ in
                await gate.enter(window.windowID)
                return (root: ComputerUseAXNode(role: "AXWindow", title: "Note"), complete: true)
            }
        )
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
        let windows = Self.windows
        let system = ComputerUseSystem(
            runningApps: { [] },
            window: { windows[$0] },
            screenshot: { _ in throw ComputerUseSystemError.captureFailed("unused") },
            axTree: { window, _, _ in
                await gate.enter(window.windowID)
                throw ComputerUseSystemError.captureFailed("Notes failed")
            }
        )
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
        let system = ComputerUseSystem(
            runningApps: { [] },
            window: { _ in lookups.next() == 1 ? notesWindow : recycled },
            screenshot: { _ in ComputerUseScreenshot(png: Data([0x89]), pixelSize: CGSize(width: 1, height: 1), scale: 1) },
            axTree: { _, _, _ in (ComputerUseAXNode(role: "AXWindow"), true) }
        )
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
