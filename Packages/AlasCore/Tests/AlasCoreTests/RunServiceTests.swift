import Foundation
import Testing
@testable import AlasCore

@MainActor
struct RunServiceTests {
    @Test(.timeLimit(.minutes(1)))
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

    @Test(.timeLimit(.minutes(1)))
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

    @Test(.timeLimit(.minutes(1)))
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
        #expect(kill(pid, 0) != 0, "the SIGTERM-ignoring child is gone")
    }
}
