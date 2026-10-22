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
