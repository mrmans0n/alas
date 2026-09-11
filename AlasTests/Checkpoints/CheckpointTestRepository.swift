import Foundation
import Testing
@testable import Alas

struct CheckpointTestRepository: Sendable {
    let root: URL
    let target: CheckpointWorktreeTarget

    static func make() async throws -> Self {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("checkpoint-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            for args in [["init", "-b", "main"], ["config", "user.name", "Checkpoint Tests"],
                         ["config", "user.email", "checkpoints@example.test"], ["config", "commit.gpgsign", "false"],
                         ["config", "core.hooksPath", "/dev/null"], ["config", "core.filemode", "true"],
                         ["commit", "--allow-empty", "-m", "seed"]] {
                let result = try await Process.git(args, cwd: root)
                guard result.exitCode == 0 else { throw ProcessError.nonZeroExit(result.exitCode, result.stderr) }
            }
            let lineage = try #require(WorktreeService.localLineageID(forWorktreeAt: root))
            return Self(root: root, target: .init(worktreeID: UUID().uuidString, projectID: "test", path: root,
                                                 lineageID: lineage, branch: "main", repositoryName: "test", workspaceName: nil))
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
    func write(_ text: String, to path: String) throws { try write(Data(text.utf8), to: path) }
    func write(_ data: Data, to path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    func symlink(_ target: String, at path: String) throws {
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent(path).path, withDestinationPath: target)
    }
    @discardableResult
    func git(_ args: [String]) async throws -> Data {
        let result = try await Process.gitData(args, cwd: root)
        guard result.exitCode == 0 else { throw ProcessError.nonZeroExit(result.exitCode, result.stderr) }
        return result.stdout
    }
    func stage(_ path: String) async throws { try await git(["add", "--", path]) }
    func commitAll(_ message: String) async throws {
        try await git(["add", "-A"])
        try await git(["commit", "-m", message])
    }
    func head(_ path: String) async throws -> Data { try await git(["show", "HEAD:\(path)"]) }
    func index(_ path: String) async throws -> Data { try await git(["show", ":\(path)"]) }
    func disk(_ path: String) throws -> Data { try Data(contentsOf: root.appendingPathComponent(path)) }
    func diskPermissions(_ path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(path).path)
        return try #require(attributes[.posixPermissions] as? NSNumber).intValue
    }
    func indexMode(_ path: String) async throws -> String {
        let record = try await git(["ls-files", "--stage", "--", path])
        return String(String(decoding: record, as: UTF8.self).prefix(6))
    }
    func status() async throws -> Data { try await git(["status", "--porcelain=v2", "-z", "--untracked-files=all"]) }
}
