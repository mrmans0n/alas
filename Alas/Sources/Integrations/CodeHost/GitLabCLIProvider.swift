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
        let base = Self.normalizedBaseBranch(baseBranch, remoteName: remote.remoteName)
        var args = [
            "mr", "create",
            "--source-branch", branch,
            "--target-branch", base,
            "--title", title,
            "--description", body,
            "--yes",
            "-R", remote.repositorySlug,
        ]
        if let headProject = Self.qualifiedHeadProject(
            headOwner: headOwner,
            baseOwner: remote.owner,
            repository: remote.repository
        ) {
            args.append(contentsOf: ["--head", headProject])
        }
        if isDraft {
            args.append("--draft")
        }

        let result = try await runner.run("glab", args: args, cwd: cwd)
        guard result.exitCode == 0 else {
            throw CodeHostProviderError.commandFailed(command: "glab mr create", stderr: result.stderr)
        }

        return try Self.parseCreateOutput(result.stdout)
    }

    func checks(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewCheck] {
        _ = (remote, request, cwd)
        return []
    }

    func rerunFailedChecks(remote: CodeHostRemote, branch: String, headSHA: String, cwd: URL) async throws {
        _ = (remote, branch, headSHA, cwd)
    }

    static func normalizedBaseBranch(_ baseBranch: String, remoteName: String) -> String {
        let prefix = "\(remoteName)/"
        guard baseBranch.hasPrefix(prefix) else { return baseBranch }
        return String(baseBranch.dropFirst(prefix.count))
    }

    static func qualifiedHeadProject(headOwner: String?, baseOwner: String, repository: String) -> String? {
        guard let headOwner = headOwner?.trimmingCharacters(in: .whitespacesAndNewlines),
              !headOwner.isEmpty,
              headOwner != baseOwner
        else {
            return nil
        }
        return "\(headOwner)/\(repository)"
    }

    static func parseCreateOutput(_ stdout: String) throws -> URL {
        for token in stdout.split(whereSeparator: \.isWhitespace) {
            let candidate = String(token).trimmingCharacters(in: .gitLabCreateOutputURLDelimiters)
            if let url = URL(string: candidate), url.isHTTPOrHTTPS {
                return url
            }
        }
        throw CodeHostProviderError.malformedOutput("glab mr create returned an invalid URL")
    }
}

private extension CharacterSet {
    static let gitLabCreateOutputURLDelimiters = CharacterSet(charactersIn: ".,;:)]}>\"'")
}

private extension URL {
    var isHTTPOrHTTPS: Bool {
        (scheme == "http" || scheme == "https") && !(host ?? "").isEmpty
    }
}
