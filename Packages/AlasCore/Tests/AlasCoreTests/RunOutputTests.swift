import Foundation
import Testing
@testable import AlasCore

@MainActor
struct RunOutputTests {
    /// A finished run's kept output is read back for its own project, and a
    /// run of another project is not found there.
    @Test func outputIsReadWithinTheRunsProject() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-run-output-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = ProjectsManager(persistedProjects: ["p1", "p2"].map {
            ProjectConfig(id: $0, name: $0, path: root.appendingPathComponent($0).path, color: "blue", addedAt: .distantPast)
        })
        for id in ["p1", "p2"] {
            projects.insertOptimisticWorktree(Worktree(
                id: "w-\(id)", projectId: id, name: id, branch: "main",
                path: root.appendingPathComponent(id), status: .clean, lastActivity: .distantPast
            ))
        }
        let history = try RunHistoryStore(path: root.appendingPathComponent("run-history.sqlite").path)
        for id in ["p1", "p2"] {
            _ = try await history.append(RunHistoryEntry(
                id: "run-\(id)", scriptKey: "dev", scriptName: "dev", worktreeID: "w-\(id)", branch: "main",
                target: RunExecutionTarget(host: nil, workingDirectory: root.path), endpoint: nil, outcome: .succeeded,
                startedAt: Date(timeIntervalSince1970: 1), finishedAt: Date(timeIntervalSince1970: 2), portConflict: nil,
                output: .available(text: "out \(id)\n", truncated: false)
            ))
        }
        let host = AlasHost(core: AlasCoreContext(projects: projects, runHistoryStore: history))

        #expect(await host.runs.output(of: "run-p1", projectID: "p1") == .text("out p1\n"))
        #expect(await host.runs.output(of: "run-p2", projectID: "p1") == .unknownRun)
    }
}
