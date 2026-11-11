import SwiftUI

/// Asks which VM to pause so an agent's call can start its worktree's VM. Reuses the permission
/// card's look, like the computer-use approval card.
struct VMSlotCard: View {
    let request: VMSlotRequest
    let onAnswer: (VMSlotChoice) -> Void

    static func options(for request: VMSlotRequest) -> [(option: ACPPermissionCardContent.Option, choice: VMSlotChoice)] {
        request.candidates.map { candidate in
            (
                .init(optionId: "pause:\(candidate.recordID)", name: "Pause \(candidate.name)", kind: "allow_once", description: nil),
                .pause(recordID: candidate.recordID)
            )
        } + [(.init(optionId: "decline", name: "Don't start", kind: "reject_once", description: nil), .decline)]
    }

    var body: some View {
        let options = Self.options(for: request)
        ACPPermissionCard(
            content: ACPPermissionCardContent(
                heading: "Worktree VM",
                title: "Both VM slots are busy",
                reason: "macOS runs two VMs at once. Pause one to start this worktree's VM?",
                options: options.map(\.option)
            )
        ) { chosen in
            if let match = options.first(where: { $0.option.optionId == chosen.optionId }) {
                onAnswer(match.choice)
            }
        }
    }
}

/// Shown in a session while one of its calls waits for its worktree's VM to boot.
struct VMStartingCard: View {
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        HStack(spacing: scale.space[2]) {
            ProgressView().controlSize(.small)
            Text("Starting this worktree's VM…")
                .font(scale.metaFont)
                .foregroundStyle(theme.color("fg-muted"))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, scale.space[3]).padding(.vertical, scale.space[2])
        .background(theme.color("bg-2").opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: scale.radius.medium))
        .overlay(RoundedRectangle(cornerRadius: scale.radius.medium).strokeBorder(theme.color("line"), lineWidth: 0.5))
    }
}
