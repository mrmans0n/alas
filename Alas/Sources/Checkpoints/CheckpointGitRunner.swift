import Foundation

protocol CheckpointGitRunning: Sendable {
    func run(_ args: [String], cwd: URL, environment: [String: String]) async throws -> ProcessResult
    func runData(_ args: [String], cwd: URL, environment: [String: String]) async throws -> ProcessResultData
}

struct LiveCheckpointGitRunner: CheckpointGitRunning {
    func run(_ args: [String], cwd: URL, environment: [String: String] = [:]) async throws -> ProcessResult {
        let invocation = try invocation(args, cwd: cwd)
        return try await Process.run(invocation.executable, args: invocation.args, cwd: invocation.cwd,
                                     env: gitEnvironment(environment))
    }

    func runData(_ args: [String], cwd: URL, environment: [String: String] = [:]) async throws -> ProcessResultData {
        let invocation = try invocation(args, cwd: cwd)
        return try await Process.runData(invocation.executable, args: invocation.args, cwd: invocation.cwd,
                                         env: gitEnvironment(environment))
    }

    private func invocation(_ args: [String], cwd: URL) throws -> GitInvocation {
        guard !cwd.isRemoteAlasPath else { throw CheckpointSnapshotError.remoteTarget }
        return GitInvocation.build(gitArgs: args, cwd: cwd, host: nil)
    }

    private func gitEnvironment(_ overrides: [String: String]) -> [String: String] {
        var environment = Process.gitEnv()
        if let index = overrides["GIT_INDEX_FILE"] { environment["GIT_INDEX_FILE"] = index }
        return environment
    }
}
