import Foundation
import Testing
@testable import AlasCore
@testable import AlasHostCore

@MainActor
struct RunServiceTests {
    @Test(.timeLimit(.minutes(5)))
    func launchedScriptReceivesItsExactRunIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scriptURL = root.appendingPathComponent("identity's script.sh")
        try #"printf '%s\n' "$ALAS_RUN_ID" "$ALAS_RUN_SCRIPT_KEY" "$ALAS_WORKTREE_ID" "$ALAS_PROJECT_ID" > identity"#
            .write(to: scriptURL, atomically: true, encoding: .utf8)
        let script = RunScript(
            scope: .repo, fileName: scriptURL.lastPathComponent, fileURL: scriptURL,
            displayName: "Identity", onExit: .close, cwd: nil, isExecutable: false
        )
        let worktree = Worktree(
            id: "worktree's id", projectId: "project's id", name: "main", branch: "main", path: root,
            status: .clean, lastActivity: Date()
        )
        let project = ProjectConfig(id: "project's id", name: "p", path: root.path, color: "blue", addedAt: Date())
        for _ in 0..<2 {
            let runID = UUID().uuidString
            _ = try await RunService().run(script, in: worktree, project: project, runID: runID)
            let received = try String(contentsOf: root.appendingPathComponent("identity"), encoding: .utf8)
            #expect(received == "\(runID)\n\(script.key)\n\(worktree.id)\n\(project.id)\n")
        }
    }

    @Test(.timeLimit(.minutes(5)))
    func failsInsteadOfWaitingWhenTheShellExitsWithoutPublishingCompletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = RunScript(
            scope: .repo, fileName: "noop.sh", fileURL: root.appendingPathComponent("noop.sh"),
            displayName: "Noop", onExit: .close, cwd: nil, isExecutable: false
        )
        let worktree = Worktree(
            id: root.path, projectId: "p", name: "main", branch: "main", path: root,
            status: .clean, lastActivity: Date()
        )
        let project = ProjectConfig(id: "p", name: "p", path: root.path, color: "blue", addedAt: Date())
        let service = RunService(launch: { _, _ in 7 })

        await #expect(throws: RunService.RunError.completionNotPublished(exitCode: 7)) {
            _ = try await service.run(script, in: worktree, project: project)
        }
    }

    @Test(.timeLimit(.minutes(5)))
    func cancellingARunStopsTheScript() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let started = root.appendingPathComponent("started")
        let scriptURL = root.appendingPathComponent("long.sh")
        try "touch \(started.path)\nsleep 300\n".write(to: scriptURL, atomically: true, encoding: .utf8)
        let script = RunScript(
            scope: .repo, fileName: "long.sh", fileURL: scriptURL,
            displayName: "Long", onExit: .close, cwd: nil, isExecutable: false
        )
        let worktree = Worktree(
            id: root.path, projectId: "p", name: "main", branch: "main", path: root,
            status: .clean, lastActivity: Date()
        )
        let project = ProjectConfig(id: "p", name: "p", path: root.path, color: "blue", addedAt: Date())
        let service = RunService()

        let runID = UUID().uuidString
        let capture = try RunScriptCompletionMonitor.paths(runID: runID, host: nil).paths
        let run = Task { try await service.run(script, in: worktree, project: project, runID: runID) }
        let deadline = ContinuousClock.now + .seconds(30)
        while !FileManager.default.fileExists(atPath: started.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        run.cancel()

        await #expect(throws: CancellationError.self) { _ = try await run.value }
        #expect(!FileManager.default.fileExists(atPath: capture.transcript), "a cancelled run leaves no capture behind")
    }

    @Test(.timeLimit(.minutes(5)))
    func cancellationKillsProcessesThatIgnoreSIGTERM() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let childPID = root.appendingPathComponent("child")
        let shellScript = "trap '' TERM; sh -c 'trap \"\" TERM; echo $$ > \(childPID.path); sleep 300'"

        let run = Task { try await RunService.runInShell(shellScript, root) }
        let deadline = ContinuousClock.now + .seconds(30)
        while (try? String(contentsOf: childPID, encoding: .utf8))?.isEmpty ?? true, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let pid = try #require(pid_t(String(contentsOf: childPID, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        run.cancel()

        await #expect(throws: CancellationError.self) { _ = try await run.value }
        #expect(try await Self.processExits(pid), Self.exitFailure(pid))
    }

    @Test(.timeLimit(.minutes(5)))
    func cancellationReachesCommandsInScriptsOwnSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let childPID = root.appendingPathComponent("child")
        let scriptURL = root.appendingPathComponent("stubborn.sh")
        // `/usr/bin/script` starts this in a new session; it ignores both TERM and HUP.
        try "trap '' TERM HUP\necho $$ > \(childPID.path)\nwhile :; do sleep 1; done\n"
            .write(to: scriptURL, atomically: true, encoding: .utf8)
        let script = RunScript(
            scope: .repo, fileName: "stubborn.sh", fileURL: scriptURL,
            displayName: "Stubborn", onExit: .close, cwd: nil, isExecutable: false
        )
        let worktree = Worktree(
            id: root.path, projectId: "p", name: "main", branch: "main", path: root,
            status: .clean, lastActivity: Date()
        )
        let project = ProjectConfig(id: "p", name: "p", path: root.path, color: "blue", addedAt: Date())

        let run = Task { try await RunService().run(script, in: worktree, project: project) }
        let deadline = ContinuousClock.now + .seconds(30)
        while (try? String(contentsOf: childPID, encoding: .utf8))?.isEmpty ?? true, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let pid = try #require(pid_t(String(contentsOf: childPID, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { _ = kill(pid, SIGKILL) }
        run.cancel()

        await #expect(throws: CancellationError.self) { _ = try await run.value }
        #expect(try await Self.processExits(pid), "the script command in script's own session is gone")
    }

    /// A killed process still needs to be scheduled and reaped, so poll for it
    /// with a deadline rather than checking once.
    private static func processExits(_ pid: pid_t) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while isAlive(pid), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        return !isAlive(pid)
    }

    private static func exitFailure(_ pid: pid_t) -> Comment {
        let processGroup = getpgid(pid)
        #if os(Linux)
        do {
            let stat = try String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8)
            return Comment(rawValue: "Child \(pid), group \(processGroup), still present: \(stat)")
        } catch {
            return Comment(rawValue: "Child \(pid), group \(processGroup), stat unavailable: \(error)")
        }
        #else
        return Comment(rawValue: "Child \(pid), group \(processGroup), still present")
        #endif
    }

    /// A zombie is dead, only not reaped yet: in a container whose init doesn't
    /// reap (CI's `tail -f /dev/null`), an orphan stays one.
    private static func isAlive(_ pid: pid_t) -> Bool {
        guard kill(pid, 0) == 0 else { return false }
        #if os(Linux)
        // /proc/<pid>/stat: "pid (comm) state …"; comm may contain spaces or parens.
        if let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
           let close = stat.lastIndex(of: ")"),
           stat[stat.index(after: close)...].trimmingCharacters(in: .whitespaces).first == "Z" {
            return false
        }
        #endif
        return true
    }
}
