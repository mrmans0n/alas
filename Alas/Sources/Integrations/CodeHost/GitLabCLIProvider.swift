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
        let base = Self.normalizedBaseBranch(baseBranch, remoteName: remote.remoteName)
        let result = try await runner.run(
            "glab",
            args: [
                "mr", "list",
                "--source-branch", branch,
                "--target-branch", base,
                "--output", "json",
                "--per-page", "20",
                "-R", remote.repositorySlug,
            ],
            cwd: cwd
        )
        guard result.exitCode == 0 else {
            throw CodeHostProviderError.commandFailed(command: "glab mr list", stderr: result.stderr)
        }

        guard let request = try Self.parseMRList(result.stdout, remote: remote, headOwner: headOwner) else {
            return nil
        }

        let detailedRequest = (try? await reviewRequestDetails(remote: remote, request: request, cwd: cwd)) ?? request
        let threads = (try? await unresolvedDiscussions(remote: remote, request: detailedRequest, cwd: cwd)) ?? []
        return Self.withEnrichment(threads: threads, checks: [], on: detailedRequest)
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

    private func reviewRequestDetails(
        remote: CodeHostRemote,
        request: ReviewRequest,
        cwd: URL
    ) async throws -> ReviewRequest {
        let result = try await runner.run(
            "glab",
            args: ["mr", "view", "\(request.number)", "--output", "json", "-R", remote.repositorySlug],
            cwd: cwd
        )
        guard result.exitCode == 0 else {
            throw CodeHostProviderError.commandFailed(command: "glab mr view", stderr: result.stderr)
        }

        return try Self.parseMRView(result.stdout, remote: remote)
    }

    private func unresolvedDiscussions(
        remote: CodeHostRemote,
        request: ReviewRequest,
        cwd: URL
    ) async throws -> [ReviewThreadSummary] {
        let result = try await runner.run(
            "glab",
            args: [
                "mr", "note", "list", "\(request.number)",
                "--state", "unresolved",
                "--output", "json",
                "-R", remote.repositorySlug,
            ],
            cwd: cwd
        )
        guard result.exitCode == 0 else {
            throw CodeHostProviderError.commandFailed(command: "glab mr note list", stderr: result.stderr)
        }

        return []
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

    static func parseMRList(_ json: String, remote: CodeHostRemote, headOwner: String?) throws -> ReviewRequest? {
        let data = Data(json.utf8)
        let items: [MRListItem]
        do {
            items = try JSONDecoder().decode([MRListItem].self, from: data)
        } catch {
            throw CodeHostProviderError.malformedOutput("Unable to parse glab mr list output")
        }

        guard let item = items.first else {
            return nil
        }

        if let headOwner = headOwner?.trimmingCharacters(in: .whitespacesAndNewlines), !headOwner.isEmpty {
            let itemsWithSourceProject = items.filter { $0.sourceProjectNamespace != nil }
            if !itemsWithSourceProject.isEmpty {
                guard let item = itemsWithSourceProject.first(where: { $0.matchesSourceProjectOwner(headOwner) }) else {
                    return nil
                }
                return try reviewRequest(from: item, remote: remote, context: "glab mr list")
            }

            guard items.count == 1 else {
                return nil
            }
        }

        return try reviewRequest(from: item, remote: remote, context: "glab mr list")
    }

    static func parseMRView(_ json: String, remote: CodeHostRemote) throws -> ReviewRequest {
        let data = Data(json.utf8)
        let item: MRListItem
        do {
            item = try JSONDecoder().decode(MRListItem.self, from: data)
        } catch {
            throw CodeHostProviderError.malformedOutput("Unable to parse glab mr view output")
        }

        return try reviewRequest(from: item, remote: remote, context: "glab mr view")
    }

    private static func reviewRequest(
        from item: MRListItem,
        remote: CodeHostRemote,
        context: String
    ) throws -> ReviewRequest {
        guard let number = item.iid else {
            throw CodeHostProviderError.malformedOutput("\(context) output is missing a merge request iid")
        }
        guard let url = URL(string: item.webURL), url.isHTTPOrHTTPS else {
            throw CodeHostProviderError.malformedOutput("\(context) returned an invalid URL")
        }

        return ReviewRequest(
            remote: remote,
            number: number,
            title: item.title,
            url: url,
            state: mapState(item.state),
            isDraft: item.isDraft,
            headRefName: item.sourceBranch,
            baseRefName: item.targetBranch,
            reviewDecision: mapReviewDecision(approvalsRequired: item.approvalsRequired, approvalsLeft: item.approvalsLeft),
            mergeState: mapMergeState(detailed: item.detailedMergeStatus, fallback: item.mergeStatus),
            checks: [],
            threads: []
        )
    }

    private static func mapState(_ value: String) -> ReviewRequestState {
        switch value.lowercased() {
        case "opened", "open": .open
        case "merged": .merged
        case "closed": .closed
        default: .open
        }
    }

    private static func mapReviewDecision(approvalsRequired: Int?, approvalsLeft: Int?) -> ReviewDecision {
        guard let approvalsRequired, approvalsRequired > 0 else {
            return .unknown
        }
        guard let approvalsLeft else {
            return .unknown
        }
        return approvalsLeft == 0 ? .approved : .reviewRequired
    }

    private static func mapMergeState(detailed: String?, fallback: String?) -> ReviewMergeState {
        switch (detailed ?? fallback)?.lowercased() {
        case "mergeable", "can_be_merged":
            .clean
        case "conflict", "conflicts", "cannot_be_merged", "need_rebase":
            .dirty
        case "cannot_be_merged_recheck", "checking", "unchecked", "preparing", "ci_still_running", "commits_status",
             "approvals_syncing", "not_ready":
            .unstable
        case "requested_changes", "blocked_status", "ci_must_pass", "discussions_not_resolved", "not_approved",
             "draft_status", "external_status_checks", "security_policy_pipeline_check":
            .blocked
        default:
            .unknown
        }
    }

    private static func withEnrichment(
        threads: [ReviewThreadSummary],
        checks: [ReviewCheck],
        on request: ReviewRequest
    ) -> ReviewRequest {
        ReviewRequest(
            remote: request.remote,
            number: request.number,
            title: request.title,
            url: request.url,
            state: request.state,
            isDraft: request.isDraft,
            headRefName: request.headRefName,
            baseRefName: request.baseRefName,
            reviewDecision: request.reviewDecision,
            mergeState: request.mergeState,
            checks: checks,
            threads: threads
        )
    }
}

private struct MRListItem: Decodable {
    let id: Int?
    let iid: Int?
    let title: String
    let webURL: String
    let state: String
    let draft: Bool?
    let workInProgress: Bool?
    let sourceBranch: String
    let targetBranch: String
    let mergeStatus: String?
    let detailedMergeStatus: String?
    let approvalsRequired: Int?
    let approvalsLeft: Int?
    let sourceProject: SourceProject?
    let sourceProjectPath: String?
    let sourceProjectPathWithNamespace: String?

    var isDraft: Bool {
        (draft ?? false) || (workInProgress ?? false)
    }

    var sourceProjectNamespace: String? {
        sourceProject?.pathWithNamespace ?? sourceProjectPathWithNamespace ?? sourceProjectPath
    }

    func matchesSourceProjectOwner(_ headOwner: String) -> Bool {
        guard let sourceProjectNamespace else {
            return false
        }
        return sourceProjectNamespace == headOwner || sourceProjectNamespace.hasPrefix("\(headOwner)/")
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case iid
        case title
        case webURL = "web_url"
        case state
        case draft
        case workInProgress = "work_in_progress"
        case sourceBranch = "source_branch"
        case targetBranch = "target_branch"
        case mergeStatus = "merge_status"
        case detailedMergeStatus = "detailed_merge_status"
        case approvalsRequired = "approvals_required"
        case approvalsLeft = "approvals_left"
        case sourceProject = "source_project"
        case sourceProjectPath = "source_project_path"
        case sourceProjectPathWithNamespace = "source_project_path_with_namespace"
    }
}

private struct SourceProject: Decodable {
    let pathWithNamespace: String?

    private enum CodingKeys: String, CodingKey {
        case pathWithNamespace = "path_with_namespace"
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
