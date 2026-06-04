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

    static func buildSelectedEvidencePrompt(snapshot: ReviewLoopSnapshot, detail: ReviewEvidenceDetail) -> String {
        let finalInstruction = "Please inspect the relevant files, explain the likely cause, and propose the smallest safe fix. Do not merge or post remote comments."
        let header: [String]
        guard let request = snapshot.reviewRequest else {
            header = [
                "Investigate this review-loop evidence item for Alas.",
                "",
                "Branch: \(snapshot.local.branchName)",
                "Base: \(snapshot.local.baseBranch)",
                "Evidence section: \(detail.item.section.displayName)",
                "",
            ]
            return buildSelectedEvidencePrompt(header: header, detail: detail, finalInstruction: finalInstruction)
        }

        header = [
            "Investigate this review-loop evidence item for Alas.",
            "",
            "\(request.provider.displayName) \(request.provider.reviewRequestLabel): \(request.url.absoluteString)",
            "Title: \(request.title)",
            "Branch: \(snapshot.local.branchName)",
            "Base: \(request.baseRefName)",
            "Head SHA: \(snapshot.local.headSHA)",
            "Evidence section: \(detail.item.section.displayName)",
            "",
        ]
        return buildSelectedEvidencePrompt(header: header, detail: detail, finalInstruction: finalInstruction)
    }

    private static func buildSelectedEvidencePrompt(
        header: [String],
        detail: ReviewEvidenceDetail,
        finalInstruction: String
    ) -> String {
        let headerText = header.joined(separator: "\n")
        let footerText = "\n\n\(finalInstruction)"
        let availableContextLength = maxPromptLength - headerText.count - footerText.count
        let context = truncateEvidenceContext(
            ReviewEvidenceContextFormatter.format(detail),
            maxLength: max(0, availableContextLength)
        )
        let prompt = headerText + context + footerText
        guard prompt.count <= maxPromptLength else {
            let availableHeaderLength = max(0, maxPromptLength - context.count - footerText.count)
            return String(headerText.prefix(availableHeaderLength)) + context + footerText
        }
        return prompt
    }

    private static func truncateEvidenceContext(_ context: String, maxLength: Int) -> String {
        guard context.count > maxLength else { return context }
        let marker = "\n\n[Evidence context truncated by Alas.]"
        guard maxLength > marker.count else {
            return String(marker.prefix(max(0, maxLength)))
        }
        return String(context.prefix(maxLength - marker.count)) + marker
    }

    private static func truncate(_ prompt: String) -> String {
        guard prompt.count > maxPromptLength else { return prompt }
        return String(prompt.prefix(maxPromptLength)) + "\n\n[Context truncated by Alas.]"
    }
}
