import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform

/// Pure text for the turns the stack shepherd sends to the owning session,
/// and for the Ship stack button's request.
public enum StackShepherdPromptBuilder {
    public static let header = "Alas stack shepherd"

    /// Sent by the toolbar's Ship stack button. The agent organizes the work
    /// into the stack; `stack_ship` publishes it and starts the shepherd.
    public static func shipPrompt(kind: CodeHostKind) -> String {
        let requests = kind == .gitlab ? "merge requests" : "pull requests"
        let request = kind == .gitlab ? "merge request" : "pull request"
        return "Ship this gg stack: publish each entry as its own \(request) and have Alas watch the \(requests). "
            + "If there are uncommitted changes that belong to this work, fold them into the stack first, one logical change per commit: "
            + "`gg absorb` (or `gg mv <entry id>` then `gg sc --staged-only`) for changes to existing entries, new commits for new changes. "
            + "gg turns each commit message into its \(request)'s title and description, so make every message describe its change. "
            + "Then run `gg last` to return to the top of the stack and call stack_ship."
    }

    /// One turn for every entry in `fixes`, bottom-up, and for the `landed`
    /// entries gg still lists, which `stack_ship` rebases away. `logs` holds
    /// the failing-check logs by request number.
    public static func fixPrompt(
        record: StackShepherdRecord,
        fixes: [StackShepherdFix],
        landed: [StackShepherdEntry] = [],
        logs: [Int: [ShepherdCheckLog]],
        rules: ShepherdRules
    ) -> ShepherdPrompt {
        let label = record.remote.kind == .gitlab ? "merge requests" : "pull requests"
        var sections = [identity(record)]
        if !landed.isEmpty {
            sections.append(landedSection(record, landed: landed, alsoFixing: !fixes.isEmpty))
        }
        if !fixes.isEmpty {
            sections.append("Some \(label) in this stack need attention. Fix them from the bottom of the stack up, then call stack_ship to publish the stack.")
            sections += fixes.map { entrySection($0, logs: logs[$0.entry.requestNumber] ?? []) }
            sections.append(howToWork(record))
            if let rulesSection = ShepherdPromptBuilder.projectRulesSection(rules) { sections.append(rulesSection) }
        }
        return ShepherdPrompt(
            text: sections.joined(separator: "\n\n"),
            card: fixCard(record: record, fixes: fixes, landed: landed, logs: logs)
        )
    }

    /// Context for a session that just became the stack's owner. Lists
    /// current problems by name only; the next fix turn carries the details.
    public static func bindPrompt(record: StackShepherdRecord, requests: [Int: ReviewRequest], rules: ShepherdRules) -> ShepherdPrompt {
        let label = record.remote.kind == .gitlab ? "merge request" : "pull request"
        var sections = [
            identity(record),
            """
            Alas is now watching every \(label) in this stack and will send problems to this session as new turns: failing checks, review threads from trusted reviewers, and merge conflicts. Fix entries bottom-up with gg and publish with stack_ship. Never push stack branches with git push.
            Call pr_status any time to see the stack's current state.
            """,
        ]
        var lines: [String] = []
        var items: [ACPPromptCard.Item] = []
        for entry in record.openEntries {
            guard let request = requests[entry.requestNumber] else { continue }
            let problems = ShepherdPolicy.problems(in: request, handled: entry.shepherd.handledThreadRevisions ?? [])
            let prefix = "Entry \(entry.position) · \(reference(entry, kind: record.remote.kind))"
            if problems.hasConflict {
                lines.append("- \(prefix): merge conflict with \(request.baseRefName)")
                items.append(.init(bodyMarkdown: "\(prefix): merge conflict", status: .conflict))
            }
            for check in problems.failingChecks {
                let what = check.bucket == .cancel ? "cancelled check" : "failing check"
                lines.append("- \(prefix): \(what) \(ShepherdPromptBuilder.checkTitle(check))")
                items.append(.init(
                    bodyMarkdown: "\(prefix): \(ShepherdPromptBuilder.checkTitle(check))", url: check.detailURL,
                    status: check.bucket == .cancel ? .cancelled : .failed))
            }
            for thread in problems.threads {
                lines.append("- \(prefix): review thread at \(ShepherdPromptBuilder.threadLocation(thread)) from @\(thread.author ?? "unknown")")
                var item = ShepherdPromptBuilder.threadItem(thread, includesBody: false)
                item.bodyMarkdown = prefix
                items.append(item)
            }
        }
        if lines.isEmpty {
            sections.append("Nothing needs attention right now.")
        } else {
            sections.append((["## Current problems"] + lines
                + ["Alas sends the details and logs in a follow-up turn when it asks for a fix."]).joined(separator: "\n"))
        }
        if let rulesSection = ShepherdPromptBuilder.projectRulesSection(rules) { sections.append(rulesSection) }
        let cardSections: [ACPPromptCard.Section] = items.isEmpty ? [] : [.init(title: "Current problems", items: items)]
        return ShepherdPrompt(text: sections.joined(separator: "\n\n"), card: card(record, sections: cardSections))
    }

    // MARK: - Sections

    private static func identity(_ record: StackShepherdRecord) -> String {
        let count = record.openEntries.count
        let label = record.remote.kind == .gitlab ? "merge request" : "pull request"
        return "\(header) · gg stack \"\(record.id.stackName)\" → \(record.base) · \(count) open \(label)\(count == 1 ? "" : "s")"
    }

    private static func entrySection(_ fix: StackShepherdFix, logs: [ShepherdCheckLog]) -> String {
        let request = fix.request
        var branchLine = "Move here with `gg mv \(fix.entry.entryID)`. Branch \(request.headRefName) → \(request.baseRefName)"
        if let head = request.headSHA, !head.isEmpty { branchLine += " · head \(head.prefix(7))" }
        var sections = [
            "# Entry \(fix.entry.position) · \(request.displayIdentity) \"\(request.title)\"\n\(branchLine)",
        ]
        if fix.problems.hasConflict {
            sections.append("""
            ## Merge conflict with \(request.baseRefName)
            This entry no longer applies cleanly on its base. Run `gg rebase` from the top of the stack, resolve each conflict from the intended behavior, and run `gg continue` after each one.
            """)
        }
        if !fix.problems.failingChecks.isEmpty {
            sections.append(ShepherdPromptBuilder.checksSection(fix.problems.failingChecks, logs: logs))
        }
        if !fix.problems.threads.isEmpty {
            sections.append(ShepherdPromptBuilder.threadsSection(fix.problems.threads))
        }
        return sections.joined(separator: "\n\n")
    }

    /// Landing an entry merges its request but leaves its commit in the
    /// local stack; `stack_ship` rebases it away before it syncs.
    private static func landedSection(_ record: StackShepherdRecord, landed: [StackShepherdEntry], alsoFixing: Bool) -> String {
        let kind = record.remote.kind
        let lines = landed.map { "- Entry \($0.position) · \(reference($0, kind: kind)) \"\($0.title)\"" }
        let when = alsoFixing ? "Once the fixes below are in, call stack_ship" : "Call stack_ship now"
        let requests = kind == .gitlab ? "merge requests" : "pull requests"
        return (["# Landed on \(record.base)"] + lines + [
            "These merged, but this worktree's stack still holds their commits. \(when) from the top of the stack (`gg last`): "
                + "it rebases the stack onto the latest \(record.base), which drops what landed, then publishes the remaining entries with gg sync and retargets their \(requests). "
                + "Don't run gg sync yourself first: before the rebase it would push the landed commits again. "
                + "If the rebase stops on a conflict, resolve it, run `gg continue`, and call stack_ship again.",
        ]).joined(separator: "\n")
    }

    private static func howToWork(_ record: StackShepherdRecord) -> String {
        let bullets = [
            "Work from the bottom of the stack up: changing an entry rewrites every entry above it.",
            "For each entry, run `gg mv <entry id>`, make the fix, stage only the files you changed, and fold them into that entry with `gg sc --staged-only`. If gg pauses on a conflict, resolve it and run `gg continue`, or `gg abort` to roll back.",
            "When every entry is fixed, run `gg last` to return to the top of the stack and call stack_ship once. Never push stack branches with git push.",
        ] + ShepherdPromptBuilder.findingRules(record.remote.kind)
        return (["# How to work on this stack"] + bullets.map { "- \($0)" }).joined(separator: "\n")
    }

    // MARK: - Cards

    private static func card(_ record: StackShepherdRecord, sections: [ACPPromptCard.Section]) -> ACPPromptCard {
        ACPPromptCard(
            origin: .shepherd,
            title: "gg stack \(record.id.stackName)",
            facts: [
                .init(kind: .branch, text: "\(record.id.stackName) → \(record.base)"),
                .init(kind: .provider, text: record.remote.kind.displayName),
            ],
            sections: sections
        )
    }

    private static func fixCard(
        record: StackShepherdRecord,
        fixes: [StackShepherdFix],
        landed: [StackShepherdEntry],
        logs: [Int: [ShepherdCheckLog]]
    ) -> ACPPromptCard {
        var sections: [ACPPromptCard.Section] = []
        if !landed.isEmpty {
            sections.append(.init(title: "Landed on \(record.base): restack with stack_ship", items: landed.map {
                .init(bodyMarkdown: "Entry \($0.position) · \(reference($0, kind: record.remote.kind)) \($0.title)")
            }))
        }
        sections += fixes.map { fix -> ACPPromptCard.Section in
            var items: [ACPPromptCard.Item] = []
            if fix.problems.hasConflict {
                items.append(.init(bodyMarkdown: "Conflicts with `\(fix.request.baseRefName)`", status: .conflict))
            }
            items += ShepherdPromptBuilder.checkItems(fix.problems.failingChecks, logs: logs[fix.entry.requestNumber] ?? [])
            items += fix.problems.threads.map { ShepherdPromptBuilder.threadItem($0, includesBody: true) }
            return .init(title: "Entry \(fix.entry.position) · \(reference(fix.entry, kind: record.remote.kind)) \(fix.request.title)", items: items)
        }
        return card(record, sections: sections)
    }

    private static func reference(_ entry: StackShepherdEntry, kind: CodeHostKind) -> String {
        "\(kind.reviewRequestNumberPrefix)\(entry.requestNumber)"
    }
}
