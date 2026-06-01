import Foundation

enum ACPStarterPrompt: String, CaseIterable, Identifiable {
    case reviewChanges
    case findBug
    case planFeature

    var id: String { rawValue }

    var label: String {
        switch self {
        case .reviewChanges:
            return "Review current changes"
        case .findBug:
            return "Find a bug"
        case .planFeature:
            return "Plan a feature"
        }
    }

    var promptText: String {
        switch self {
        case .reviewChanges:
            return "Review the current changes in this worktree and suggest the next steps."
        case .findBug:
            return "Look for likely bugs or fragile spots in this worktree. Start by inspecting the current changes."
        case .planFeature:
            return "Help me plan this feature. Ask clarifying questions first if the goal is ambiguous."
        }
    }

    func applying(to draft: ACPComposerDraft) -> ACPComposerDraft {
        let prompt = ACPComposerDraft(segments: [.text(promptText)])
        if draft.isEmpty { return prompt }

        var segments = draft.segments
        if case .text(let text) = segments[segments.count - 1] {
            segments[segments.count - 1] = .text(text + "\n\n")
        } else {
            segments.append(.text("\n\n"))
        }
        return ACPComposerDraft(segments: segments + prompt.segments)
    }
}
