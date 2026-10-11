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
}
