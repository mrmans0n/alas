import Foundation

struct GitLabCLIProvider: CodeHostProvider {
    let kind: CodeHostKind = .gitlab
    let capabilities: CodeHostProviderCapabilities = .gitlabCLI

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

        let sourceProjectPathsByID = try await sourceProjectPathsByID(
            fromMRListJSON: result.stdout,
            headOwner: headOwner,
            remote: remote,
            cwd: cwd
        )
        guard let request = try Self.parseMRList(
            result.stdout,
            remote: remote,
            headOwner: headOwner,
            sourceProjectPathsByID: sourceProjectPathsByID
        ) else {
            return nil
        }

        let detailedRequest = (try? await reviewRequestDetails(remote: remote, request: request, cwd: cwd)) ?? request
        let threads = (try? await unresolvedDiscussions(remote: remote, request: detailedRequest, cwd: cwd)) ?? []
        let checks = (try? await checks(remote: remote, request: detailedRequest, cwd: cwd)) ?? []
        return Self.withEnrichment(threads: threads, checks: checks, on: detailedRequest)
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
        let result = try await runner.run(
            "glab",
            args: [
                "ci", "get",
                "--merge-request", "\(request.number)",
                "--with-job-details",
                "--output", "json",
                "-R", remote.repositorySlug,
            ],
            cwd: cwd
        )
        if result.exitCode != 0, Self.isNoPipelineReported(result) {
            return []
        }
        guard result.exitCode == 0 else {
            throw CodeHostProviderError.commandFailed(command: "glab ci get", stderr: result.stderr)
        }

        return try Self.parsePipeline(result.stdout)
    }

    func failedCheckEvidence(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewEvidenceItem] {
        request.checks
            .filter { $0.bucket == .fail }
            .map {
                ReviewEvidenceItem(
                    id: $0.id,
                    section: .ci,
                    title: $0.name,
                    subtitle: $0.workflow,
                    status: .failed,
                    providerURL: $0.detailURL
                )
            }
    }

    func checkEvidenceDetail(
        remote: CodeHostRemote,
        request: ReviewRequest,
        item: ReviewEvidenceItem,
        cwd: URL
    ) async throws -> ReviewEvidenceDetail {
        _ = request
        guard let jobID = Self.gitLabJobID(from: item.providerURL) else {
            return ReviewEvidenceDetail(
                item: item,
                body: "Open this job in GitLab to inspect full logs.",
                filePath: nil,
                line: nil,
                isTruncated: false
            )
        }

        let result = try await runner.run(
            "glab",
            args: ["ci", "trace", jobID, "-R", remote.repositorySlug],
            cwd: cwd
        )
        guard result.exitCode == 0 else {
            throw CodeHostProviderError.commandFailed(command: "glab ci trace", stderr: result.stderr)
        }

        return ReviewEvidenceDetail.truncated(
            item: item,
            body: result.stdout,
            filePath: nil,
            line: nil
        )
    }

    func feedbackEvidenceDetail(
        remote: CodeHostRemote,
        request: ReviewRequest,
        item: ReviewEvidenceItem,
        cwd: URL
    ) async throws -> ReviewEvidenceDetail {
        _ = remote
        _ = cwd
        if item.id == ReviewEvidenceFallbacks.changesRequestedID {
            return ReviewEvidenceFallbacks.changesRequestedDetail(item: item, request: request)
        }
        let thread = request.threads.first { $0.id == item.id }
        return ReviewEvidenceDetail(
            item: item,
            body: thread?.body ?? "Open this discussion in GitLab to inspect full context.",
            filePath: nil,
            line: nil,
            isTruncated: false
        )
    }

    func rerunFailedChecks(
        remote: CodeHostRemote,
        branch: String,
        headSHA: String,
        request: ReviewRequest?,
        cwd: URL
    ) async throws {
        _ = headSHA
        var args = ["ci", "get"]
        if let request {
            args.append(contentsOf: ["--merge-request", "\(request.number)"])
        } else {
            args.append(contentsOf: ["--branch", branch])
        }
        args.append(contentsOf: [
            "--status", "failed",
            "--with-job-details",
            "--output", "json",
            "-R", remote.repositorySlug,
        ])

        let result = try await runner.run(
            "glab",
            args: args,
            cwd: cwd
        )
        if result.exitCode != 0, Self.isNoPipelineReported(result) {
            return
        }
        guard result.exitCode == 0 else {
            throw CodeHostProviderError.commandFailed(command: "glab ci get", stderr: result.stderr)
        }

        let retryTargets = try Self.failedJobRetryTargets(fromPipelineJSON: result.stdout)
        for target in retryTargets {
            let retry = try await runner.run(
                "glab",
                args: [
                    "ci", "retry", "\(target.jobID)",
                    "--pipeline-id", "\(target.pipelineID)",
                    "-R", remote.repositorySlug,
                ],
                cwd: cwd
            )
            guard retry.exitCode == 0 else {
                throw CodeHostProviderError.commandFailed(command: "glab ci retry", stderr: retry.stderr)
            }
        }
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

    private func sourceProjectPathsByID(
        fromMRListJSON json: String,
        headOwner: String?,
        remote: CodeHostRemote,
        cwd: URL
    ) async throws -> [Int: String] {
        guard let headOwner = Self.normalizedOptionalString(headOwner), !headOwner.isEmpty else {
            return [:]
        }

        let items = try Self.decodeMRList(json)
        var pathsByID: [Int: String] = [:]
        let idsToResolve = Set(items.compactMap { item -> Int? in
            guard item.sourceProjectNamespace(sourceProjectPathsByID: [:]) == nil else {
                return nil
            }
            return item.sourceProjectID
        })

        for id in idsToResolve.sorted() {
            let result = try await runner.run(
                "glab",
                args: ["api", "projects/\(id)", "--hostname", remote.host, "--output", "json"],
                cwd: cwd
            )
            guard result.exitCode == 0 else {
                throw CodeHostProviderError.commandFailed(command: "glab api projects/\(id)", stderr: result.stderr)
            }
            pathsByID[id] = try Self.parseProjectPath(result.stdout)
        }

        return pathsByID
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

        return try Self.parseDiscussions(result.stdout, requestURL: request.url)
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

    static func parseMRList(
        _ json: String,
        remote: CodeHostRemote,
        headOwner: String?,
        sourceProjectPathsByID: [Int: String] = [:]
    ) throws -> ReviewRequest? {
        let items = try decodeMRList(json)

        guard let item = items.first else {
            return nil
        }

        if let headOwner = headOwner?.trimmingCharacters(in: .whitespacesAndNewlines), !headOwner.isEmpty {
            let itemsWithSourceProject = items.filter { $0.sourceProjectNamespace(sourceProjectPathsByID: sourceProjectPathsByID) != nil }
            if !itemsWithSourceProject.isEmpty {
                guard let item = itemsWithSourceProject.first(where: {
                    $0.matchesSourceProjectOwner(headOwner, sourceProjectPathsByID: sourceProjectPathsByID)
                }) else {
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

    static func parseProjectPath(_ json: String) throws -> String {
        let data = Data(json.utf8)
        let project: GitLabProject
        do {
            project = try JSONDecoder().decode(GitLabProject.self, from: data)
        } catch {
            throw CodeHostProviderError.malformedOutput("Unable to parse glab api project output")
        }
        guard let path = normalizedOptionalString(project.pathWithNamespace) else {
            throw CodeHostProviderError.malformedOutput("glab api project output is missing path_with_namespace")
        }
        return path
    }

    private static func decodeMRList(_ json: String) throws -> [MRListItem] {
        let data = Data(json.utf8)
        do {
            return try JSONDecoder().decode([MRListItem].self, from: data)
        } catch {
            throw CodeHostProviderError.malformedOutput("Unable to parse glab mr list output")
        }
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

    static func parseDiscussions(_ json: String, requestURL: URL) throws -> [ReviewThreadSummary] {
        let data = Data(json.utf8)
        let discussions: [GitLabDiscussion]
        do {
            discussions = try JSONDecoder().decode([GitLabDiscussion].self, from: data)
        } catch {
            throw CodeHostProviderError.malformedOutput("Unable to parse glab mr note list output")
        }

        return try discussions.compactMap { discussion in
            guard let note = discussion.notes.first(where: { note in
                !note.isSystem && !note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) else {
                return nil
            }

            return ReviewThreadSummary(
                id: discussion.id,
                author: note.author?.username,
                body: note.body,
                url: try discussionURL(note: note, requestURL: requestURL),
                isResolved: discussion.isResolved,
                isActionable: !discussion.isResolved
            )
        }
    }

    static func parsePipeline(_ json: String) throws -> [ReviewCheck] {
        let pipeline = try decodePipeline(json)

        let workflow = normalizedOptionalString(pipeline.ref)
        if let jobs = pipeline.jobs, !jobs.isEmpty {
            return try jobs.map { job in
                let detailURL = try parseOptionalHTTPURL(
                    job.webURL,
                    context: "glab ci get returned an invalid URL"
                )
                return ReviewCheck(
                    id: checkID(for: job, pipeline: pipeline),
                    name: job.name,
                    workflow: workflow,
                    bucket: mapCheckBucket(job.status, allowFailure: job.allowFailure),
                    detailURL: detailURL,
                    completedAt: try parseOptionalGitLabDate(job.finishedAt)
                )
            }
        }

        let detailURL = try parseOptionalHTTPURL(
            pipeline.webURL,
            context: "glab ci get returned an invalid URL"
        )
        let completedAt = try parseOptionalGitLabDate(pipeline.finishedAt)
            ?? parseOptionalGitLabDate(pipeline.updatedAt)
        return [
            ReviewCheck(
                id: checkID(for: pipeline),
                name: "pipeline",
                workflow: workflow,
                bucket: mapCheckBucket(pipeline.status),
                detailURL: detailURL,
                completedAt: completedAt
            ),
        ]
    }

    private static func decodePipeline(_ json: String) throws -> GitLabPipeline {
        let data = Data(json.utf8)
        do {
            return try JSONDecoder().decode(GitLabPipeline.self, from: data)
        } catch {
            throw CodeHostProviderError.malformedOutput("Unable to parse glab ci get output")
        }
    }

    private static func failedJobRetryTargets(fromPipelineJSON json: String) throws -> [GitLabRetryTarget] {
        let pipeline = try decodePipeline(json)
        let failedJobs = pipeline.jobs?.filter { job in
            job.status.lowercased() == "failed" && job.allowFailure != true
        } ?? []

        guard !failedJobs.isEmpty else {
            if pipeline.status.lowercased() == "failed" {
                throw CodeHostProviderError.malformedOutput("glab ci get output did not include retryable failed job IDs")
            }
            return []
        }

        guard let pipelineID = pipeline.id else {
            throw CodeHostProviderError.malformedOutput("glab ci get output is missing a pipeline id for retry")
        }

        return try failedJobs.map { job in
            guard let jobID = job.id else {
                throw CodeHostProviderError.malformedOutput("glab ci get output did not include retryable failed job IDs")
            }
            return GitLabRetryTarget(jobID: jobID, pipelineID: pipelineID)
        }
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

    private static func mapCheckBucket(_ status: String) -> ReviewCheckBucket {
        mapCheckBucket(status, allowFailure: false)
    }

    private static func mapCheckBucket(_ status: String, allowFailure: Bool?) -> ReviewCheckBucket {
        if status.lowercased() == "failed", allowFailure == true {
            return .skipping
        }
        switch status.lowercased() {
        case "success":
            return .pass
        case "failed":
            return .fail
        case "running", "pending", "created", "preparing", "waiting_for_resource", "manual", "scheduled":
            return .pending
        case "canceled", "cancelled":
            return .cancel
        case "skipped":
            return .skipping
        default:
            return .unknown
        }
    }

    private static func isNoPipelineReported(_ result: ProcessResult) -> Bool {
        let output = "\(result.stdout)\n\(result.stderr)".lowercased()
        return output.contains("no pipeline")
            || output.contains("no pipelines")
            || output.contains("pipeline not found")
    }

    private static func parseOptionalHTTPURL(_ value: String?, context: String) throws -> URL? {
        guard let value = normalizedOptionalString(value) else {
            return nil
        }
        guard let url = URL(string: value), url.isHTTPOrHTTPS else {
            throw CodeHostProviderError.malformedOutput(context)
        }
        return url
    }

    private static func parseOptionalGitLabDate(_ value: String?) throws -> Date? {
        guard let value = normalizedOptionalString(value) else {
            return nil
        }
        if let date = parseDate(value, formatOptions: [.withInternetDateTime]) {
            return date
        }
        if let date = parseDate(value, formatOptions: [.withInternetDateTime, .withFractionalSeconds]) {
            return date
        }
        throw CodeHostProviderError.malformedOutput("Unable to parse GitLab date")
    }

    private static func parseDate(_ value: String, formatOptions: ISO8601DateFormatter.Options) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = formatOptions
        return formatter.date(from: value)
    }

    private static func normalizedOptionalString(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func discussionURL(note: GitLabDiscussionNote, requestURL: URL) throws -> URL? {
        if let url = try parseOptionalHTTPURL(note.webURL, context: "glab mr note list returned an invalid URL") {
            return url
        }
        guard let id = note.id else {
            return nil
        }
        var components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)
        components?.fragment = "note_\(id)"
        return components?.url
    }

    static func gitLabJobID(from url: URL?) -> String? {
        guard let url else {
            return nil
        }
        let pathComponents = url.pathComponents
        guard let jobsIndex = pathComponents.firstIndex(of: "jobs") else {
            return nil
        }
        let idIndex = pathComponents.index(after: jobsIndex)
        guard idIndex < pathComponents.endIndex else {
            return nil
        }
        let id = pathComponents[idIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    private static func checkID(for pipeline: GitLabPipeline) -> String {
        encodedID([
            "gitlab-pipeline-check",
            pipeline.id.map(String.init) ?? "",
            "pipeline",
            pipeline.status,
            pipeline.webURL ?? "",
        ])
    }

    private static func checkID(for job: GitLabJob, pipeline: GitLabPipeline) -> String {
        encodedID([
            "gitlab-job-check",
            pipeline.id.map(String.init) ?? "",
            job.id.map(String.init) ?? "",
            job.name,
            job.status,
            job.webURL ?? "",
        ])
    }

    private static func encodedID(_ fields: [String]) -> String {
        fields
            .map { "\($0.utf8.count)#\($0)" }
            .joined()
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
    let sourceProjectID: Int?
    let sourceProjectPath: String?
    let sourceProjectPathWithNamespace: String?

    var isDraft: Bool {
        (draft ?? false) || (workInProgress ?? false)
    }

    func sourceProjectNamespace(sourceProjectPathsByID: [Int: String]) -> String? {
        sourceProject?.pathWithNamespace
            ?? sourceProjectPathWithNamespace
            ?? sourceProjectPath
            ?? sourceProjectID.flatMap { sourceProjectPathsByID[$0] }
    }

    func matchesSourceProjectOwner(_ headOwner: String, sourceProjectPathsByID: [Int: String]) -> Bool {
        guard let sourceProjectNamespace = sourceProjectNamespace(sourceProjectPathsByID: sourceProjectPathsByID) else {
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
        case sourceProjectID = "source_project_id"
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

private struct GitLabProject: Decodable {
    let pathWithNamespace: String?

    private enum CodingKeys: String, CodingKey {
        case pathWithNamespace = "path_with_namespace"
    }
}

private struct GitLabPipeline: Decodable {
    let id: Int?
    let status: String
    let ref: String?
    let webURL: String?
    let finishedAt: String?
    let updatedAt: String?
    let jobs: [GitLabJob]?

    private enum CodingKeys: String, CodingKey {
        case id
        case status
        case ref
        case webURL = "web_url"
        case finishedAt = "finished_at"
        case updatedAt = "updated_at"
        case jobs
    }
}

private struct GitLabJob: Decodable {
    let id: Int?
    let name: String
    let status: String
    let allowFailure: Bool?
    let webURL: String?
    let finishedAt: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case status
        case allowFailure = "allow_failure"
        case webURL = "web_url"
        case finishedAt = "finished_at"
    }
}

private struct GitLabRetryTarget {
    let jobID: Int
    let pipelineID: Int
}

private struct GitLabDiscussion: Decodable {
    let id: String
    let resolved: Bool?
    let notes: [GitLabDiscussionNote]

    var isResolved: Bool {
        if let resolved {
            return resolved
        }
        let resolvableNotes = notes.filter { $0.resolvable ?? false }
        guard !resolvableNotes.isEmpty else {
            return false
        }
        return resolvableNotes.allSatisfy { $0.resolved ?? false }
    }
}

private struct GitLabDiscussionNote: Decodable {
    let id: Int?
    let body: String
    let author: GitLabDiscussionAuthor?
    let system: Bool?
    let resolvable: Bool?
    let resolved: Bool?
    let webURL: String?

    var isSystem: Bool {
        system ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case body
        case author
        case system
        case resolvable
        case resolved
        case webURL = "web_url"
    }
}

private struct GitLabDiscussionAuthor: Decodable {
    let username: String?
}

private extension CharacterSet {
    static let gitLabCreateOutputURLDelimiters = CharacterSet(charactersIn: ".,;:)]}>\"'")
}

private extension URL {
    var isHTTPOrHTTPS: Bool {
        (scheme == "http" || scheme == "https") && !(host ?? "").isEmpty
    }
}
