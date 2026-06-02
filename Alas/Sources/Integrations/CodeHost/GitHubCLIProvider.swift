import Foundation

struct GitHubCLIProvider: CodeHostProvider {
    let kind: CodeHostKind = .github
    let capabilities: CodeHostProviderCapabilities = .githubCLI

    private let runner: any CodeHostCommandRunning

    init(runner: any CodeHostCommandRunning = ProcessCodeHostCommandRunner()) {
        self.runner = runner
    }

    func isAvailable() async -> Bool {
        do {
            let result = try await runner.run("gh", args: ["--version"], cwd: nil)
            return result.exitCode == 0
        } catch {
            return false
        }
    }

    func isAuthenticated(remote: CodeHostRemote, cwd: URL) async -> Bool {
        do {
            let result = try await runner.run(
                "gh",
                args: ["auth", "status", "--hostname", remote.host],
                cwd: cwd
            )
            return result.exitCode == 0
        } catch {
            return false
        }
    }

    func currentReviewRequest(remote: CodeHostRemote, branch: String, cwd: URL) async throws -> ReviewRequest? {
        let result = try await runner.run(
            "gh",
            args: [
                "pr", "list",
                "--head", branch,
                "--state", "open",
                "--limit", "1",
                "--json", "number,title,url,state,isDraft,headRefName,baseRefName,reviewDecision,mergeStateStatus",
                "-R", remote.repositorySlug,
            ],
            cwd: cwd
        )
        guard result.exitCode == 0 else {
            throw CodeHostProviderError.commandFailed(command: "gh pr list", stderr: result.stderr)
        }

        return try Self.parsePRList(result.stdout, remote: remote)
    }

    func createReviewRequest(
        remote: CodeHostRemote,
        branch: String,
        baseBranch: String,
        title: String,
        body: String,
        cwd: URL
    ) async throws -> URL {
        let result = try await runner.run(
            "gh",
            args: [
                "pr", "create",
                "--base", baseBranch,
                "--head", branch,
                "--title", title,
                "--body", body,
                "-R", remote.repositorySlug,
            ],
            cwd: cwd
        )
        guard result.exitCode == 0 else {
            throw CodeHostProviderError.commandFailed(command: "gh pr create", stderr: result.stderr)
        }

        return try Self.parseCreateOutput(result.stdout)
    }

    func checks(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewCheck] {
        let result = try await runner.run(
            "gh",
            args: [
                "pr", "checks", "\(request.number)",
                "--json", "bucket,completedAt,description,event,link,name,startedAt,state,workflow",
                "-R", remote.repositorySlug,
            ],
            cwd: cwd
        )
        if result.exitCode == 1, Self.isNoChecksReported(result) {
            return []
        }
        guard result.exitCode == 0 || result.exitCode == 8 else {
            throw CodeHostProviderError.commandFailed(command: "gh pr checks", stderr: result.stderr)
        }

        return try Self.parseChecks(result.stdout)
    }

    func rerunFailedChecks(remote: CodeHostRemote, branch: String, cwd: URL) async throws {
        let listResult = try await runner.run(
            "gh",
            args: [
                "run", "list",
                "--branch", branch,
                "--status", "failure",
                "--limit", "20",
                "--json", "databaseId,status,conclusion,url",
                "-R", remote.repositorySlug,
            ],
            cwd: cwd
        )
        guard listResult.exitCode == 0 else {
            throw CodeHostProviderError.commandFailed(command: "gh run list", stderr: listResult.stderr)
        }

        for runID in try Self.parseRunIDs(listResult.stdout) {
            let rerunResult = try await runner.run(
                "gh",
                args: ["run", "rerun", "\(runID)", "--failed", "-R", remote.repositorySlug],
                cwd: cwd
            )
            guard rerunResult.exitCode == 0 else {
                throw CodeHostProviderError.commandFailed(command: "gh run rerun", stderr: rerunResult.stderr)
            }
        }
    }

    static func parsePRList(_ json: String, remote: CodeHostRemote) throws -> ReviewRequest? {
        let data = Data(json.utf8)
        let items: [PRListItem]
        do {
            items = try JSONDecoder().decode([PRListItem].self, from: data)
        } catch {
            throw CodeHostProviderError.malformedOutput("Unable to parse gh pr list output")
        }

        guard let item = items.first else {
            return nil
        }
        guard let url = URL(string: item.url), url.isHTTPOrHTTPS else {
            throw CodeHostProviderError.malformedOutput("gh pr list returned an invalid URL")
        }

        return ReviewRequest(
            remote: remote,
            number: item.number,
            title: item.title,
            url: url,
            state: mapState(item.state),
            isDraft: item.isDraft,
            headRefName: item.headRefName,
            baseRefName: item.baseRefName,
            reviewDecision: mapReviewDecision(item.reviewDecision),
            mergeState: mapMergeState(item.mergeStateStatus),
            checks: [],
            threads: []
        )
    }

    static func parseChecks(_ json: String) throws -> [ReviewCheck] {
        let data = Data(json.utf8)
        let items: [CheckItem]
        do {
            items = try JSONDecoder().decode([CheckItem].self, from: data)
        } catch {
            throw CodeHostProviderError.malformedOutput("Unable to parse gh pr checks output")
        }

        return try items.map { item in
            let detailURL = item.link.flatMap(URL.init(string:))
            if let detailURL, !detailURL.isHTTPOrHTTPS {
                throw CodeHostProviderError.malformedOutput("gh pr checks returned an invalid URL")
            }

            let completedAt = try parseOptionalDate(item.completedAt)
            _ = try parseOptionalDate(item.startedAt)

            return ReviewCheck(
                id: checkID(for: item),
                name: item.name,
                workflow: item.workflow,
                bucket: mapBucket(item.bucket),
                detailURL: detailURL,
                completedAt: completedAt
            )
        }
    }

    static func parseCreateOutput(_ stdout: String) throws -> URL {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.isHTTPOrHTTPS else {
            throw CodeHostProviderError.malformedOutput("gh pr create returned an invalid URL")
        }
        return url
    }

    private static func isNoChecksReported(_ result: ProcessResult) -> Bool {
        let output = "\(result.stdout)\n\(result.stderr)".lowercased()
        return output.contains("no checks reported")
    }

    static func parseLatestRunID(_ json: String) throws -> Int? {
        try parseRunIDs(json).first
    }

    static func parseRunIDs(_ json: String) throws -> [Int] {
        let data = Data(json.utf8)
        let items: [RunItem]
        do {
            items = try JSONDecoder().decode([RunItem].self, from: data)
        } catch {
            throw CodeHostProviderError.malformedOutput("Unable to parse gh run list output")
        }
        return items.map(\.databaseId)
    }

    private static func mapState(_ value: String) -> ReviewRequestState {
        switch value.uppercased() {
        case "OPEN": .open
        case "MERGED": .merged
        case "CLOSED": .closed
        default: .open
        }
    }

    private static func mapReviewDecision(_ value: String?) -> ReviewDecision {
        switch value?.uppercased() {
        case "APPROVED": .approved
        case "CHANGES_REQUESTED": .changesRequested
        case "REVIEW_REQUIRED": .reviewRequired
        default: .unknown
        }
    }

    private static func mapMergeState(_ value: String?) -> ReviewMergeState {
        switch value?.uppercased() {
        case "CLEAN": .clean
        case "BLOCKED": .blocked
        case "DIRTY": .dirty
        case "UNSTABLE": .unstable
        default: .unknown
        }
    }

    private static func mapBucket(_ value: String) -> ReviewCheckBucket {
        ReviewCheckBucket(rawValue: value.lowercased()) ?? .unknown
    }

    private static func parseOptionalDate(_ value: String?) throws -> Date? {
        guard let value else {
            return nil
        }
        if let date = parseDate(value, formatOptions: [.withInternetDateTime]) {
            return date
        }
        if let date = parseDate(value, formatOptions: [.withInternetDateTime, .withFractionalSeconds]) {
            return date
        }
        throw CodeHostProviderError.malformedOutput("Unable to parse GitHub date")
    }

    private static func parseDate(_ value: String, formatOptions: ISO8601DateFormatter.Options) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = formatOptions
        return formatter.date(from: value)
    }

    private static func checkID(for item: CheckItem) -> String {
        let fields = [
            "github-check",
            item.workflow ?? "",
            item.name,
            item.bucket,
            item.description ?? "",
            item.event ?? "",
            item.link ?? "",
            item.state ?? "",
            item.startedAt ?? "",
            item.completedAt ?? "",
        ]
        return fields
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: "|")
    }

}

private struct PRListItem: Decodable {
    let number: Int
    let title: String
    let url: String
    let state: String
    let isDraft: Bool
    let headRefName: String
    let baseRefName: String
    let reviewDecision: String?
    let mergeStateStatus: String?
}

private struct CheckItem: Decodable {
    let bucket: String
    let completedAt: String?
    let description: String?
    let event: String?
    let link: String?
    let name: String
    let startedAt: String?
    let state: String?
    let workflow: String?
}

private struct RunItem: Decodable {
    let databaseId: Int
}

private extension URL {
    var isHTTPOrHTTPS: Bool {
        scheme == "http" || scheme == "https"
    }
}
