import Foundation

struct GitLabCLIProvider: CodeHostProvider {
    let kind: CodeHostKind = .gitlab
    let capabilities: CodeHostProviderCapabilities = .readOnly

    private let runner: any CodeHostCommandRunning

    init(runner: any CodeHostCommandRunning = ProcessCodeHostCommandRunner()) {
        self.runner = runner
    }

    func isAvailable() async -> Bool {
        do {
            let result = try await runner.run("glab", args: ["--version"], cwd: nil)
            return result.exitCode == 0
        } catch {
            return false
        }
    }

    func isAuthenticated(remote: CodeHostRemote, cwd: URL) async -> Bool {
        do {
            let result = try await runner.run(
                "glab",
                args: ["auth", "status", "--hostname", remote.host],
                cwd: cwd
            )
            return result.exitCode == 0
        } catch {
            return false
        }
    }

    func currentReviewRequest(
        remote: CodeHostRemote,
        branch: String,
        headOwner: String?,
        baseBranch: String,
        cwd: URL
    ) async throws -> ReviewRequest? {
        _ = (remote, branch, headOwner, baseBranch, cwd)
        return nil
    }

    func createReviewRequest(
        remote: CodeHostRemote,
        branch: String,
        headOwner: String?,
        baseBranch: String,
        title: String,
        body: String,
        isDraft: Bool,
        cwd: URL
    ) async throws -> URL {
        _ = (branch, headOwner, baseBranch, title, body, isDraft, cwd)
        return remote.webURL
    }

    func checks(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewCheck] {
        _ = (remote, request, cwd)
        return []
    }

    func rerunFailedChecks(remote: CodeHostRemote, branch: String, headSHA: String, cwd: URL) async throws {
        _ = (remote, branch, headSHA, cwd)
    }
}
