import Foundation

enum ReviewLoopHandoffBuilder {
    private static let maxPromptLength = 4_500

    static func build(snapshot: ReviewLoopSnapshot, action: ReviewLoopAction) -> String {
        guard let request = snapshot.reviewRequest else {
            return """
            Investigate the current branch review loop.

            Branch: \(snapshot.local.branchName)
            Base: \(snapshot.local.baseBranch)
            State: \(action.detail)

            Start by inspecting the local git state and explain what should happen next.
            """
        }

        var lines: [String] = [
            "Investigate this review-loop item for Alas.",
            "",
            "\(request.provider.displayName) \(request.provider.reviewRequestLabel): \(request.url.absoluteString)",
            "Title: \(request.title)",
            "Branch: \(snapshot.local.branchName)",
            "Base: \(request.baseRefName)",
            "Head SHA: \(snapshot.local.headSHA)",
            "Next action: \(action.title)",
            "",
        ]

        if action.kind == .prepareCheckFailureHandoff,
           let check = request.checks.first(where: { $0.bucket == .fail }) {
            lines.append("Failing check: \(check.name)")
            if let workflow = check.workflow {
                lines.append("Workflow: \(workflow)")
            }
            if let url = check.detailURL {
                lines.append("Check URL: \(url.absoluteString)")
            }
            lines.append("")
        }

        if action.kind == .prepareReviewHandoff {
            lines.append("Review decision: \(request.reviewDecision.rawValue)")
            let actionableThreads = request.threads
                .filter { !$0.isResolved && $0.isActionable }
                .prefix(3)
            for thread in actionableThreads {
                lines.append("- \(thread.author ?? "reviewer"): \(thread.body.prefix(600))")
            }
            lines.append("")
        }

        lines.append("Please inspect the relevant files, explain the likely cause, and propose the smallest safe fix. Do not merge or post remote comments.")
        return truncate(lines.joined(separator: "\n"))
    }

    private static func truncate(_ prompt: String) -> String {
        guard prompt.count > maxPromptLength else { return prompt }
        return String(prompt.prefix(maxPromptLength)) + "\n\n[Context truncated by Alas.]"
    }
}
