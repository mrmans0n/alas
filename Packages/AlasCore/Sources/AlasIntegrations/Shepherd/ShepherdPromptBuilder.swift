import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform

/// The tail of one failed check's log, as returned by `checkEvidenceDetail`.
public struct ShepherdCheckLog: Equatable, Sendable {
    public let checkID: String
    public let body: String
    public let isTruncated: Bool
    public let url: URL?

    public init(checkID: String, body: String, isTruncated: Bool, url: URL?) {
        self.checkID = checkID
        self.body = body
        self.isTruncated = isTruncated
        self.url = url
    }
}

/// A shepherd turn: the instruction the agent receives and the card the
/// transcript shows in its place.
public struct ShepherdPrompt: Equatable, Sendable {
    public let text: String
    public let card: ACPPromptCard
}

/// Pure text for the turns the shepherd sends to the owning session.
public enum ShepherdPromptBuilder {
    public static let header = "Alas PR shepherd"
    public static let maxCheckLogs = 3
    /// Log lines a card shows per check; the text carries the full tail.
    public static let cardLogLines = 12

    /// A backtick fence longer than any backtick run in `text` (at least 3),
    /// so untrusted text such as a check log can't close it early.
    private static func fence(for text: String) -> String {
        var longest = 0
        var current = 0
        for character in text {
            current = character == "`" ? current + 1 : 0
            longest = max(longest, current)
        }
        return String(repeating: "`", count: max(3, longest + 1))
    }

    public static func fixPrompt(
        request: ReviewRequest,
        fix: ShepherdFixRequest,
        logs: [ShepherdCheckLog],
        rules: ShepherdRules
    ) -> ShepherdPrompt {
        var sections = [
            identity(request),
            """
            The \(request.provider.reviewRequestLabel) needs attention. Fix what's below, commit, and push to \(request.headRefName).
            Never force-push or rewrite published history. When done, call pr_status to confirm.
            """,
        ]
        if fix.hasConflict { sections.append(conflictSection(request)) }
        if !fix.failingChecks.isEmpty { sections.append(checksSection(fix.failingChecks, logs: logs)) }
        if !fix.threads.isEmpty { sections.append(threadsSection(fix.threads)) }
        sections.append(howToWork(request.provider))
        if let rulesSection = projectRulesSection(rules) { sections.append(rulesSection) }
        return ShepherdPrompt(text: sections.joined(separator: "\n\n"), card: fixCard(request: request, fix: fix, logs: logs))
    }

    /// Context for a session that just became the owner (bind, adopt, or
    /// rebind). Lists current problems by name only; the next fix turn
    /// carries logs and full threads.
    public static func bindPrompt(request: ReviewRequest, fix: ShepherdFixRequest, rules: ShepherdRules) -> ShepherdPrompt {
        let label = request.provider.reviewRequestLabel
        var sections = [
            identity(request),
            """
            Alas is now watching this \(label) and will send problems to this session as new turns: failing checks, review threads from trusted reviewers, and merge conflicts with \(request.baseRefName).
            Never force-push or rewrite published history. Call pr_status any time to see the current state.
            """,
        ]
        if fix.isEmpty {
            sections.append("Nothing needs attention right now.")
        } else {
            var lines = ["## Current problems"]
            if fix.hasConflict { lines.append("- Merge conflict with \(request.baseRefName)") }
            lines += fix.failingChecks.map {
                ($0.bucket == .cancel ? "- Cancelled check: " : "- Failing check: ") + checkTitle($0)
            }
            lines += fix.threads.map { "- Review thread at \(threadLocation($0)) from @\($0.author ?? "unknown")" }
            lines.append("Alas sends the details and logs in a follow-up turn when it asks for a fix.")
            sections.append(lines.joined(separator: "\n"))
        }
        if let rulesSection = projectRulesSection(rules) { sections.append(rulesSection) }
        return ShepherdPrompt(text: sections.joined(separator: "\n\n"), card: bindCard(request: request, fix: fix))
    }

    /// Sent by the toolbar popover's Ship with agent button.
    public static func createPrompt(kind: CodeHostKind) -> String {
        let article = kind == .gitlab ? "an" : "a"
        return "Open \(article) \(kind.reviewRequestLabel) for the work on this branch. "
            + "If there are uncommitted changes that belong to this work, commit them first. "
            + "Write the title and description from the actual diff and this conversation, then call pr_create."
    }

    // MARK: - Sections

    private static func identity(_ request: ReviewRequest) -> String {
        var branchLine = "Branch \(request.headRefName) → \(request.baseRefName)"
        if let head = request.headSHA, !head.isEmpty { branchLine += " · head \(head.prefix(7))" }
        return "\(header) · \(request.displayIdentity) \"\(request.title)\"\n\(branchLine)"
    }

    private static func conflictSection(_ request: ReviewRequest) -> String {
        """
        ## Merge conflict with \(request.baseRefName)
        Merge \(request.remote.remoteName)/\(request.baseRefName) into \(request.headRefName), resolve each conflict from the intended behavior, commit, push.
        """
    }

    private static func checksSection(_ checks: [ReviewCheck], logs: [ShepherdCheckLog]) -> String {
        let logsByID = Dictionary(logs.map { ($0.checkID, $0) }, uniquingKeysWith: { first, _ in first })
        let heading = checks.contains { $0.bucket == .cancel } ? "Failing or cancelled checks" : "Failing checks"
        var lines = ["## \(heading) (\(checks.count))"]
        for check in checks.prefix(maxCheckLogs) {
            lines.append("### \(checkTitle(check))" + (check.bucket == .cancel ? " (cancelled)" : ""))
            let log = logsByID[check.id]
            let body = log?.body.trimmingCharacters(in: .newlines) ?? ""
            if body.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append("Log unavailable.")
            } else {
                if log?.isTruncated == true { lines.append("(last part of the log)") }
                let logFence = fence(for: body)
                lines.append(logFence + "text")
                lines.append(body)
                lines.append(logFence)
            }
            if let url = log?.url ?? check.detailURL { lines.append("Full log: \(url.absoluteString)") }
        }
        let rest = checks.dropFirst(maxCheckLogs)
        if !rest.isEmpty {
            lines.append("### Other failing checks (logs not included)")
            for check in rest {
                let marker = check.bucket == .cancel ? " (cancelled)" : ""
                lines.append("- \(checkTitle(check))\(marker)" + (check.detailURL.map { ": \($0.absoluteString)" } ?? ""))
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func threadsSection(_ threads: [ReviewThread]) -> String {
        let blocks = threads.map { thread -> String in
            var lines = ["### \(threadLocation(thread))"]
            for comment in thread.comments {
                let body = comment.body.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { continue }
                lines.append("@\(comment.author ?? "unknown") (\(comment.authorTrust.rawValue)):")
                lines += body.components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> \($0)" }
            }
            if let url = thread.url {
                lines.append("Thread: \(url.absoluteString) (id: \(thread.id))")
            } else {
                lines.append("Thread id: \(thread.id)")
            }
            return lines.joined(separator: "\n")
        }
        return "## Review threads (\(threads.count))\n" + blocks.joined(separator: "\n\n")
    }

    private static func howToWork(_ kind: CodeHostKind) -> String {
        let cli = kind == .github ? "gh" : "glab"
        return """
        ## How to work
        - Classify each finding: fix it, show it is already fixed, or reply with evidence that it is wrong. Never change code only to silence wrong feedback.
        - Batch every fix you can make now into one push.
        - Run the tests your repository instructions require for the files you touch.
        - If a check failure is unrelated to your change and the log shows a flake or infrastructure error, rerun it with \(cli) and say why.
        - A cancelled check usually needs a rerun with \(cli), not a code change.
        - Reply on threads you decline. Resolve threads you fixed.
        - If you can't make progress, say so plainly. Alas will notify the user.
        """
    }

    private static func projectRulesSection(_ rules: ShepherdRules) -> String? {
        let text = rules.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return "## Project rules\n\(text)"
    }

    // MARK: - Cards

    private static func card(_ request: ReviewRequest, sections: [ACPPromptCard.Section]) -> ACPPromptCard {
        var facts = [ACPPromptCard.Fact(kind: .branch, text: "\(request.headRefName) → \(request.baseRefName)")]
        if let head = request.headSHA, !head.isEmpty { facts.append(.init(kind: .revision, text: String(head.prefix(7)))) }
        return ACPPromptCard(
            origin: .shepherd, title: "\(request.displayIdentity) · \(request.title)",
            facts: facts, sections: sections, action: .url(request.url))
    }

    private static func fixCard(request: ReviewRequest, fix: ShepherdFixRequest, logs: [ShepherdCheckLog]) -> ACPPromptCard {
        let logsByID = Dictionary(logs.map { ($0.checkID, $0) }, uniquingKeysWith: { first, _ in first })
        var sections: [ACPPromptCard.Section] = []
        if fix.hasConflict {
            sections.append(.init(title: "Merge conflict", items: [
                .init(bodyMarkdown: "Conflicts with `\(request.baseRefName)`", status: .conflict),
            ]))
        }
        if !fix.failingChecks.isEmpty {
            let heading = fix.failingChecks.contains { $0.bucket == .cancel } ? "Failing or cancelled checks" : "Failing checks"
            let items = fix.failingChecks.enumerated().map { index, check -> ACPPromptCard.Item in
                // Only the checks the text gives a log get an excerpt.
                let log = index < maxCheckLogs ? logsByID[check.id] : nil
                return .init(
                    bodyMarkdown: checkTitle(check),
                    excerpt: log.flatMap(logExcerpt),
                    url: log?.url ?? check.detailURL,
                    status: check.bucket == .cancel ? .cancelled : .failed)
            }
            sections.append(.init(title: "\(heading) (\(fix.failingChecks.count))", items: items))
        }
        if !fix.threads.isEmpty {
            sections.append(.init(
                title: "Review threads (\(fix.threads.count))",
                items: fix.threads.map { threadItem($0, includesBody: true) }))
        }
        return card(request, sections: sections)
    }

    private static func bindCard(request: ReviewRequest, fix: ShepherdFixRequest) -> ACPPromptCard {
        guard !fix.isEmpty else { return card(request, sections: []) }
        var items: [ACPPromptCard.Item] = []
        if fix.hasConflict {
            items.append(.init(bodyMarkdown: "Merge conflict with `\(request.baseRefName)`", status: .conflict))
        }
        items += fix.failingChecks.map {
            .init(bodyMarkdown: checkTitle($0), url: $0.detailURL, status: $0.bucket == .cancel ? .cancelled : .failed)
        }
        items += fix.threads.map { threadItem($0, includesBody: false) }
        return card(request, sections: [.init(title: "Current problems", items: items)])
    }

    private static func logExcerpt(_ log: ShepherdCheckLog) -> ACPPromptCard.Excerpt? {
        let body = log.body.trimmingCharacters(in: .newlines)
        guard !body.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let lines = body.components(separatedBy: "\n")
        return .init(text: lines.suffix(cardLogLines).joined(separator: "\n"), style: .log)
    }

    private static func threadItem(_ thread: ReviewThread, includesBody: Bool) -> ACPPromptCard.Item {
        var location: ACPPromptCard.Location?
        if let path = thread.path, !path.isEmpty {
            let line = thread.isFileLevel ? nil : (thread.line ?? thread.originalLine)
            location = .init(path: path, startLine: line, endLine: line)
        }
        let comments = thread.comments.filter { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let author = comments.first.map { "@\($0.author ?? "unknown") · \($0.authorTrust.rawValue)" }
        return .init(
            location: location, author: author,
            bodyMarkdown: includesBody ? threadBody(comments) : nil,
            url: thread.url)
    }

    /// The first comment as is, then each reply under its author. Bodies keep
    /// their inner whitespace so fences and indented code stay blocks.
    private static func threadBody(_ comments: [ReviewComment]) -> String? {
        guard let first = comments.first else { return nil }
        let body = { (comment: ReviewComment) in comment.body.trimmingCharacters(in: .newlines) }
        let replies = comments.dropFirst().map {
            "**@\($0.author ?? "unknown")** (\($0.authorTrust.rawValue)):\n\n\(body($0))"
        }
        return ([body(first)] + replies).joined(separator: "\n\n")
    }

    // MARK: - Labels

    private static func checkTitle(_ check: ReviewCheck) -> String {
        guard let workflow = check.workflow, !workflow.isEmpty, workflow != check.name else { return check.name }
        return "\(check.name) (\(workflow))"
    }

    private static func threadLocation(_ thread: ReviewThread) -> String {
        guard let path = thread.path, !path.isEmpty else { return "General comment" }
        guard !thread.isFileLevel, let line = thread.line ?? thread.originalLine else { return path }
        return "\(path):\(line)"
    }
}
