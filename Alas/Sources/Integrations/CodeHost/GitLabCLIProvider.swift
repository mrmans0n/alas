import CryptoKit
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

    func reviewRequest(remote: CodeHostRemote, number: Int, cwd: URL) async throws -> ReviewRequest {
        try await refreshedReviewRequest(remote: remote, request: ReviewRequest.placeholder(remote: remote, number: number), cwd: cwd)
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

    func reviewDiff(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> String {
        let result = try await runner.run(
            "glab",
            args: ["mr", "diff", "\(request.number)", "--raw", "--color=never", "-R", remote.repositorySlug],
            cwd: cwd
        )
        guard result.exitCode == 0 else {
            throw CodeHostProviderError.commandFailed(command: "glab mr diff", stderr: result.stderr)
        }
        return result.stdout
    }

    func publishReview(_ request: ProviderReviewPublishRequest) async throws -> ProviderReviewPublishResult {
        let publishableComments = request.comments.filter { $0.side != .unknown }
        let preflightFailures = request.comments
            .filter { $0.side == .unknown }
            .map {
                ProviderReviewFailedComment(
                    localDraftID: $0.localDraftID,
                    message: "GitLab review comments require an old or new side."
                )
            }
        guard !publishableComments.isEmpty || request.comments.isEmpty else {
            return ProviderReviewPublishResult(
                published: [],
                failed: preflightFailures,
                refreshedRequest: request.reviewRequest,
                warnings: []
            )
        }

        let diffRefs = publishableComments.isEmpty
            ? nil
            : try await mergeRequestDiffRefs(remote: request.remote, request: request.reviewRequest, cwd: request.cwd)
        var published: [ProviderReviewPublishedComment] = []
        var failed: [ProviderReviewFailedComment] = preflightFailures

        for comment in publishableComments {
            guard let diffRefs else { break }
            do {
                let mapping = try await createDiscussion(
                    remote: request.remote,
                    request: request.reviewRequest,
                    comment: comment,
                    diffRefs: diffRefs,
                    cwd: request.cwd
                )
                published.append(mapping)
            } catch {
                failed.append(ProviderReviewFailedComment(localDraftID: comment.localDraftID, message: error.localizedDescription))
            }
        }
        guard request.comments.isEmpty || !published.isEmpty else {
            return ProviderReviewPublishResult(
                published: [],
                failed: failed,
                refreshedRequest: request.reviewRequest,
                warnings: []
            )
        }

        var warnings: [String] = []
        do {
            switch request.decision {
            case .comment:
                break
            case .approve:
                if failed.isEmpty {
                    try await approveMergeRequest(remote: request.remote, request: request.reviewRequest, cwd: request.cwd)
                } else {
                    warnings.append("GitLab approval was not submitted because \(failed.count) review comment(s) failed to publish.")
                }
            case .requestChanges:
                if failed.isEmpty {
                    try await createMergeRequestNote(
                        remote: request.remote,
                        request: request.reviewRequest,
                        body: request.summaryBody,
                        cwd: request.cwd
                    )
                } else {
                    warnings.append("GitLab request changes note was not submitted because \(failed.count) review comment(s) failed to publish.")
                }
            }
        } catch {
            guard !published.isEmpty else {
                throw error
            }
            warnings.append("GitLab review comments were published, but Alas could not submit the review decision: \(error.localizedDescription)")
        }

        let refreshedRequest: ReviewRequest
        do {
            refreshedRequest = try await refreshedReviewRequest(
                remote: request.remote,
                request: request.reviewRequest,
                cwd: request.cwd
            )
        } catch {
            refreshedRequest = request.reviewRequest
            warnings.append("GitLab review was published, but Alas could not refresh the MR: \(error.localizedDescription)")
        }
        return ProviderReviewPublishResult(
            published: published,
            failed: failed,
            refreshedRequest: refreshedRequest,
            warnings: warnings
        )
    }

    func mutateReviewThread(_ mutation: ProviderThreadMutation) async throws -> ProviderThreadMutationResult {
        guard let discussionID = Self.normalizedOptionalString(mutation.thread.providerThreadID) else {
            throw CodeHostProviderError.malformedOutput("GitLab thread mutation requires a discussion id.")
        }

        let providerURL: URL?
        switch mutation.kind {
        case .reply:
            guard let body = Self.normalizedOptionalString(mutation.bodyMarkdown) else {
                throw CodeHostProviderError.malformedOutput("GitLab reply requires a non-empty body.")
            }
            providerURL = try await createDiscussionNote(
                remote: mutation.remote,
                request: mutation.reviewRequest,
                discussionID: discussionID,
                body: body,
                cwd: mutation.cwd
            )
        case .resolve:
            try await setDiscussionResolved(
                remote: mutation.remote,
                request: mutation.reviewRequest,
                discussionID: discussionID,
                resolved: true,
                cwd: mutation.cwd
            )
            providerURL = nil
        case .unresolve:
            throw CodeHostProviderError.malformedOutput("GitLab unresolve is not supported until resolved discussions are loaded.")
        }

        let refreshedRequest = (try? await refreshedReviewRequest(
            remote: mutation.remote,
            request: mutation.reviewRequest,
            cwd: mutation.cwd
        )) ?? mutation.reviewRequest
        return ProviderThreadMutationResult(refreshedRequest: refreshedRequest, providerURL: providerURL)
    }

    func failedCheckEvidence(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewEvidenceItem] {
        ReviewEvidenceCIActivityMapper.items(for: request.checks)
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

    private func refreshedReviewRequest(
        remote: CodeHostRemote,
        request: ReviewRequest,
        cwd: URL
    ) async throws -> ReviewRequest {
        let refreshed = try await reviewRequestDetails(remote: remote, request: request, cwd: cwd)
        let threads = (try? await unresolvedDiscussions(remote: remote, request: refreshed, cwd: cwd)) ?? []
        let checks = (try? await checks(remote: remote, request: refreshed, cwd: cwd)) ?? []
        return Self.withEnrichment(threads: threads, checks: checks, on: refreshed)
    }

    private func mergeRequestDiffRefs(
        remote: CodeHostRemote,
        request: ReviewRequest,
        cwd: URL
    ) async throws -> GitLabDiffRefs {
        let result = try await runner.run(
            "glab",
            args: [
                "api",
                Self.mergeRequestAPIPath(remote: remote, request: request, suffix: "versions"),
                "--hostname", remote.host,
                "--output", "json",
            ],
            cwd: cwd
        )
        guard result.exitCode == 0 else {
            throw CodeHostProviderError.commandFailed(command: "glab api merge request versions", stderr: result.stderr)
        }
        return try Self.parseDiffRefs(result.stdout)
    }

    private func createDiscussion(
        remote: CodeHostRemote,
        request: ReviewRequest,
        comment: ProviderReviewDraftComment,
        diffRefs: GitLabDiffRefs,
        cwd: URL
    ) async throws -> ProviderReviewPublishedComment {
        let payload = GitLabCreateDiscussionPayload(comment: comment, diffRefs: diffRefs)
        let stdin = try Self.encodedJSON(payload)
        let result = try await runner.run(
            "glab",
            args: [
                "api",
                Self.mergeRequestAPIPath(remote: remote, request: request, suffix: "discussions"),
                "--method", "POST",
                "--hostname", remote.host,
                "--input", "-",
            ],
            cwd: cwd,
            stdin: stdin
        )
        guard result.exitCode == 0 else {
            throw CodeHostProviderError.commandFailed(command: "glab api merge request discussions", stderr: result.stderr)
        }
        return try Self.parsePublishedDiscussion(result.stdout, localDraftID: comment.localDraftID)
    }

    private func approveMergeRequest(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws {
        guard let headSHA = Self.normalizedOptionalString(request.headSHA) else {
            throw CodeHostProviderError.malformedOutput("GitLab approval requires the reviewed merge request head SHA.")
        }
        let payload = GitLabApproveMergeRequestPayload(sha: headSHA)
        let result = try await runner.run(
            "glab",
            args: [
                "api",
                Self.mergeRequestAPIPath(remote: remote, request: request, suffix: "approve"),
                "--method", "POST",
                "--hostname", remote.host,
                "--input", "-",
            ],
            cwd: cwd,
            stdin: try Self.encodedJSON(payload)
        )
        guard result.exitCode == 0 else {
            throw CodeHostProviderError.commandFailed(command: "glab api merge request approve", stderr: result.stderr)
        }
    }

    private func createMergeRequestNote(
        remote: CodeHostRemote,
        request: ReviewRequest,
        body: String,
        cwd: URL
    ) async throws {
        guard let body = Self.normalizedOptionalString(body) else {
            throw CodeHostProviderError.malformedOutput("GitLab request changes note requires a non-empty body.")
        }
        let result = try await runner.run(
            "glab",
            args: [
                "api",
                Self.mergeRequestAPIPath(remote: remote, request: request, suffix: "notes"),
                "--method", "POST",
                "--hostname", remote.host,
                "--input", "-",
            ],
            cwd: cwd,
            stdin: try Self.encodedJSON(GitLabBodyPayload(body: body))
        )
        guard result.exitCode == 0 else {
            throw CodeHostProviderError.commandFailed(command: "glab api merge request note", stderr: result.stderr)
        }
    }

    @discardableResult
    private func createDiscussionNote(
        remote: CodeHostRemote,
        request: ReviewRequest,
        discussionID: String,
        body: String,
        cwd: URL
    ) async throws -> URL? {
        let result = try await runner.run(
            "glab",
            args: [
                "api",
                Self.mergeRequestAPIPath(remote: remote, request: request, suffix: "discussions/\(discussionID)/notes"),
                "--method", "POST",
                "--hostname", remote.host,
                "--input", "-",
            ],
            cwd: cwd,
            stdin: try Self.encodedJSON(GitLabBodyPayload(body: body))
        )
        guard result.exitCode == 0 else {
            throw CodeHostProviderError.commandFailed(command: "glab api merge request discussion note", stderr: result.stderr)
        }
        return try Self.parseCreatedNoteURL(result.stdout)
    }

    private func setDiscussionResolved(
        remote: CodeHostRemote,
        request: ReviewRequest,
        discussionID: String,
        resolved: Bool,
        cwd: URL
    ) async throws {
        let result = try await runner.run(
            "glab",
            args: [
                "api",
                Self.mergeRequestAPIPath(remote: remote, request: request, suffix: "discussions/\(discussionID)"),
                "--method", "PUT",
                "--hostname", remote.host,
                "--input", "-",
            ],
            cwd: cwd,
            stdin: try Self.encodedJSON(GitLabResolveDiscussionPayload(resolved: resolved))
        )
        guard result.exitCode == 0 else {
            throw CodeHostProviderError.commandFailed(command: "glab api merge request discussion", stderr: result.stderr)
        }
    }

    static func mergeRequestAPIPath(remote: CodeHostRemote, request: ReviewRequest, suffix: String) -> String {
        "projects/\(encodedProjectPath(remote.repositorySlug))/merge_requests/\(request.number)/\(suffix)"
    }

    static func encodedProjectPath(_ projectPath: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return projectPath.addingPercentEncoding(withAllowedCharacters: allowed) ?? projectPath
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
                isActionable: !discussion.isResolved,
                location: reviewThreadLocation(from: note),
                providerThreadID: discussion.id,
                providerCommentID: note.id.map(String.init)
            )
        }
    }

    static func parseDiffRefs(_ json: String) throws -> GitLabDiffRefs {
        let data = Data(json.utf8)
        let decoder = JSONDecoder()
        do {
            if let versions = try? decoder.decode([GitLabMRVersion].self, from: data),
               let refs = versions.first?.diffRefs {
                return try refs.validated()
            }
            let version = try decoder.decode(GitLabMRVersion.self, from: data)
            return try version.diffRefs.validated()
        } catch let error as CodeHostProviderError {
            throw error
        } catch {
            throw CodeHostProviderError.malformedOutput("Unable to parse glab api merge request versions output")
        }
    }

    static func parsePublishedDiscussion(
        _ json: String,
        localDraftID: String
    ) throws -> ProviderReviewPublishedComment {
        let data = Data(json.utf8)
        let discussion: GitLabDiscussion
        do {
            discussion = try JSONDecoder().decode(GitLabDiscussion.self, from: data)
        } catch {
            throw CodeHostProviderError.malformedOutput("Unable to parse glab api merge request discussion output")
        }
        let note = discussion.notes.first { !($0.system ?? false) }
        return ProviderReviewPublishedComment(
            localDraftID: localDraftID,
            providerThreadID: discussion.id,
            providerCommentID: note?.id.map(String.init),
            providerURL: try note.flatMap {
                try parseOptionalHTTPURL($0.webURL, context: "glab api merge request discussion returned an invalid URL")
            }
        )
    }

    static func parseCreatedNoteURL(_ json: String) throws -> URL? {
        let data = Data(json.utf8)
        let note: GitLabCreatedNote
        do {
            note = try JSONDecoder().decode(GitLabCreatedNote.self, from: data)
        } catch {
            throw CodeHostProviderError.malformedOutput("Unable to parse glab api merge request discussion note output")
        }
        return try parseOptionalHTTPURL(note.webURL, context: "glab api merge request discussion note returned an invalid URL")
    }

    static func encodedJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw CodeHostProviderError.malformedOutput("Unable to encode GitLab API payload")
        }
        return string
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
            headSHA: normalizedOptionalString(item.sha),
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

    private static func reviewThreadLocation(from note: GitLabDiscussionNote) -> ReviewThreadLocation? {
        guard let position = note.position else {
            return nil
        }
        let newPath = normalizedOptionalString(position.newPath)
        let oldPath = normalizedOptionalString(position.oldPath)
        guard let path = newPath ?? oldPath else {
            return nil
        }

        let side: ReviewThreadSide
        let line: Int?
        if let newLine = position.newLine {
            side = .new
            line = newLine
        } else if let oldLine = position.oldLine {
            side = .old
            line = oldLine
        } else {
            side = .unknown
            line = nil
        }

        return ReviewThreadLocation(
            path: path,
            originalPath: oldPath,
            line: line,
            side: side,
            providerPosition: note.id.map(String.init)
        )
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
            headSHA: request.headSHA,
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
    let sha: String?
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
        case sha
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

struct GitLabDiffRefs: Codable, Equatable {
    let baseSHA: String
    let startSHA: String
    let headSHA: String

    func validated() throws -> GitLabDiffRefs {
        guard !baseSHA.isEmpty, !startSHA.isEmpty, !headSHA.isEmpty else {
            throw CodeHostProviderError.malformedOutput("glab api merge request versions output is missing diff refs")
        }
        return self
    }

    private enum CodingKeys: String, CodingKey {
        case baseSHA = "base_sha"
        case startSHA = "start_sha"
        case headSHA = "head_sha"
    }
}

private struct GitLabMRVersion: Decodable {
    let diffRefs: GitLabDiffRefs

    private enum CodingKeys: String, CodingKey {
        case diffRefs = "diff_refs"
        case baseCommitSHA = "base_commit_sha"
        case startCommitSHA = "start_commit_sha"
        case headCommitSHA = "head_commit_sha"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let diffRefs = try container.decodeIfPresent(GitLabDiffRefs.self, forKey: .diffRefs) {
            self.diffRefs = diffRefs
            return
        }
        self.diffRefs = GitLabDiffRefs(
            baseSHA: try container.decodeIfPresent(String.self, forKey: .baseCommitSHA) ?? "",
            startSHA: try container.decodeIfPresent(String.self, forKey: .startCommitSHA) ?? "",
            headSHA: try container.decodeIfPresent(String.self, forKey: .headCommitSHA) ?? ""
        )
    }
}

private struct GitLabCreateDiscussionPayload: Encodable {
    let body: String
    let position: GitLabCreateDiscussionPosition

    init(comment: ProviderReviewDraftComment, diffRefs: GitLabDiffRefs) {
        self.body = comment.bodyMarkdown
        self.position = GitLabCreateDiscussionPosition(comment: comment, diffRefs: diffRefs)
    }
}

private struct GitLabCreateDiscussionPosition: Encodable {
    let positionType = "text"
    let baseSHA: String
    let startSHA: String
    let headSHA: String
    let oldPath: String
    let newPath: String
    let oldLine: Int?
    let newLine: Int?
    let lineRange: GitLabCreateDiscussionLineRange?

    init(comment: ProviderReviewDraftComment, diffRefs: GitLabDiffRefs) {
        self.baseSHA = diffRefs.baseSHA
        self.startSHA = diffRefs.startSHA
        self.headSHA = diffRefs.headSHA
        self.oldPath = comment.originalPath ?? comment.path
        self.newPath = comment.path
        let sideType: GitLabCreateDiscussionLineRangePoint.LineType
        switch comment.side {
        case .old:
            self.oldLine = comment.lineRange.upperBound
            self.newLine = nil
            sideType = .old
        case .new:
            self.oldLine = nil
            self.newLine = comment.lineRange.upperBound
            sideType = .new
        case .unknown:
            self.oldLine = nil
            self.newLine = nil
            sideType = .old
        }
        if comment.lineRange.lowerBound == comment.lineRange.upperBound {
            self.lineRange = nil
        } else {
            self.lineRange = GitLabCreateDiscussionLineRange(
                path: sideType == .old ? self.oldPath : self.newPath,
                type: sideType,
                startLine: comment.lineRange.lowerBound,
                endLine: comment.lineRange.upperBound
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case positionType = "position_type"
        case baseSHA = "base_sha"
        case startSHA = "start_sha"
        case headSHA = "head_sha"
        case oldPath = "old_path"
        case newPath = "new_path"
        case oldLine = "old_line"
        case newLine = "new_line"
        case lineRange = "line_range"
    }
}

private struct GitLabCreateDiscussionLineRange: Encodable {
    let start: GitLabCreateDiscussionLineRangePoint
    let end: GitLabCreateDiscussionLineRangePoint

    init(
        path: String,
        type: GitLabCreateDiscussionLineRangePoint.LineType,
        startLine: Int,
        endLine: Int
    ) {
        self.start = GitLabCreateDiscussionLineRangePoint(path: path, type: type, line: startLine)
        self.end = GitLabCreateDiscussionLineRangePoint(path: path, type: type, line: endLine)
    }
}

private struct GitLabCreateDiscussionLineRangePoint: Encodable {
    enum LineType: String, Encodable {
        case old
        case new
    }

    let lineCode: String
    let type: LineType
    let oldLine: Int?
    let newLine: Int?

    init(path: String, type: LineType, line: Int) {
        self.type = type
        switch type {
        case .old:
            self.lineCode = "\(Self.sha1Hex(path))_\(line)_0"
            self.oldLine = line
            self.newLine = nil
        case .new:
            self.lineCode = "\(Self.sha1Hex(path))_0_\(line)"
            self.oldLine = nil
            self.newLine = line
        }
    }

    private enum CodingKeys: String, CodingKey {
        case lineCode = "line_code"
        case type
        case oldLine = "old_line"
        case newLine = "new_line"
    }

    private static func sha1Hex(_ value: String) -> String {
        Insecure.SHA1.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private struct GitLabBodyPayload: Encodable {
    let body: String
}

private struct GitLabApproveMergeRequestPayload: Encodable {
    let sha: String
}

private struct GitLabResolveDiscussionPayload: Encodable {
    let resolved: Bool
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
    let position: GitLabNotePosition?

    var isSystem: Bool {
        system ?? false
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(Int.self, forKey: .id)
        self.body = try container.decode(String.self, forKey: .body)
        self.author = try container.decodeIfPresent(GitLabDiscussionAuthor.self, forKey: .author)
        self.system = try container.decodeIfPresent(Bool.self, forKey: .system)
        self.resolvable = try container.decodeIfPresent(Bool.self, forKey: .resolvable)
        self.resolved = try container.decodeIfPresent(Bool.self, forKey: .resolved)
        self.webURL = try container.decodeIfPresent(String.self, forKey: .webURL)
        self.position = try? container.decode(GitLabNotePosition.self, forKey: .position)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case body
        case author
        case system
        case resolvable
        case resolved
        case webURL = "web_url"
        case position
    }
}

private struct GitLabDiscussionAuthor: Decodable {
    let username: String?
}

private struct GitLabCreatedNote: Decodable {
    let id: Int?
    let webURL: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case webURL = "web_url"
    }
}

private struct GitLabNotePosition: Decodable {
    let newPath: String?
    let oldPath: String?
    let newLine: Int?
    let oldLine: Int?

    private enum CodingKeys: String, CodingKey {
        case newPath = "new_path"
        case oldPath = "old_path"
        case newLine = "new_line"
        case oldLine = "old_line"
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
