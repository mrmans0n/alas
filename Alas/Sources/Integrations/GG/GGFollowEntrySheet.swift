import SwiftUI

/// Picks a gg stack entry for a tab to follow. Shaped like `GGReorderSheet`:
/// a bordered list of stack rows with an apply/cancel footer.
struct GGFollowEntrySheet: View {
    let presentation: GGFollowEntryPresentation
    let onFollow: (String) -> Void
    let onCancel: () -> Void

    @Environment(\.theme) private var theme
    @State private var selectedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(presentation.isEditing ? "Edit Followed Stack Entry" : "Follow Stack Entry")
                .font(.system(size: 16, weight: .semibold))
            Text("The tab tracks this commit's GG-ID across rebases, reorders, and amends.")
                .font(.system(size: 11.5))
                .foregroundStyle(theme.color("fg-dim"))

            content

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Follow") {
                    guard let selectedID, let ggID = ggID(for: selectedID) else { return }
                    onFollow(ggID)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canFollow)
            }
        }
        .padding(18)
        .frame(minWidth: 520)
        .onAppear { selectedID = presentation.selectedGGID ?? loadedModel?.selectedID }
    }

    @ViewBuilder
    private var content: some View {
        switch presentation.state {
        case .loading:
            HStack(spacing: 8) {
                Spinner().frame(width: 14, height: 14)
                Text("Loading stack…")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.color("fg-dim"))
            }
            .frame(minWidth: 480, minHeight: 260, alignment: .center)
        case .offStack:
            message("This worktree is not on a gg stack right now.")
        case .failed(let error):
            message(error, color: theme.color("warn"))
        case .loaded(let model):
            List(selection: $selectedID) {
                ForEach(model.candidates) { candidate in
                    row(candidate)
                        .tag(candidate.id)
                        .selectionDisabled(!candidate.isSelectable)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(minWidth: 480, minHeight: 260)
        }
    }

    private func message(_ text: String, color: Color? = nil) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(color ?? theme.color("fg-dim"))
            .frame(minWidth: 480, minHeight: 260, alignment: .center)
    }

    private func row(_ candidate: GGFollowEntryCandidate) -> some View {
        HStack(spacing: 10) {
            Text("\(candidate.position)")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(theme.color("fg-faint"))
                .frame(width: 18, alignment: .trailing)
            Text(candidate.title)
                .font(.system(size: 12.5))
                .lineLimit(1)
            Spacer(minLength: 8)
            if let number = candidate.prNumber {
                Text("#\(number)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(theme.color("fg-dim"))
            }
            if let ciStatus = candidate.ciStatus {
                Text(ciStatus.rawValue)
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.color("fg-faint"))
            }
            Text(candidate.ggID ?? "no GG-ID")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(theme.color(candidate.isSelectable ? "fg-faint" : "warn"))
                .lineLimit(1)
        }
        .frame(height: 30)
        .opacity(candidate.isSelectable ? 1 : 0.55)
    }

    private var loadedModel: GGFollowEntryModel? {
        guard case .loaded(let model) = presentation.state else { return nil }
        return model
    }

    private var canFollow: Bool {
        guard let selectedID else { return false }
        return ggID(for: selectedID) != nil
    }

    private func ggID(for id: String) -> String? {
        loadedModel?.candidates.first { $0.id == id }?.ggID
    }
}
