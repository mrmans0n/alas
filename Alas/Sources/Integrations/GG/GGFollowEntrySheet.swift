import SwiftUI

/// Picks a gg stack entry for a tab to follow. Shaped like `GGReorderSheet`:
/// a bordered list of stack rows with an apply/cancel footer.
struct GGFollowEntrySheet: View {
    let presentation: GGFollowEntryPresentation
    let onFollow: (String) -> Void
    let onCancel: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale
    @State private var selectedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: scale.space[3]) {
            Text(presentation.isEditing ? "Edit Followed Stack Entry" : "Follow Stack Entry")
                .font(scale.title.font)
            Text("The tab tracks this commit's GG-ID across rebases, reorders, and amends.")
                .font(scale.meta.font)
                .foregroundStyle(theme.color("fg-dim"))

            content

            HStack(spacing: scale.space[2]) {
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
        .padding(scale.space[4])
        .frame(minWidth: 520)
        .onAppear { selectedID = presentation.selectedGGID ?? loadedModel?.selectedID }
        .onChange(of: presentation.state) { _, _ in
            // The sheet is presented while the stack is still loading
            // (`presentation.state == .loading`), so `onAppear` fires before
            // there is anything to preselect. Re-seed once the load resolves,
            // without clobbering a selection the user already made.
            guard selectedID == nil else { return }
            selectedID = presentation.selectedGGID ?? loadedModel?.selectedID
        }
    }

    @ViewBuilder
    private var content: some View {
        switch presentation.state {
        case .loading:
            HStack(spacing: scale.space[2]) {
                Spinner().frame(width: 14, height: 14)
                Text("Loading stack…")
                    .font(scale.meta.font)
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
            .font(scale.meta.font)
            .foregroundStyle(color ?? theme.color("fg-dim"))
            .frame(minWidth: 480, minHeight: 260, alignment: .center)
    }

    private func row(_ candidate: GGFollowEntryCandidate) -> some View {
        HStack(spacing: scale.space[3]) {
            Text("\(candidate.position)")
                .font(scale.caption.font(weight: .regular, design: .monospaced))
                .foregroundStyle(theme.color("fg-faint"))
                .frame(width: 18, alignment: .trailing)
            Text(candidate.title)
                .font(scale.meta.font)
                .lineLimit(1)
            Spacer(minLength: scale.space[2])
            if let number = candidate.prNumber {
                Text(verbatim: "#\(number)")
                    .font(scale.caption.font(weight: .regular, design: .monospaced))
                    .foregroundStyle(theme.color("fg-dim"))
            }
            if let ciStatus = candidate.ciStatus {
                Text(ciStatus.rawValue)
                    .font(scale.caption.font(weight: .regular))
                    .foregroundStyle(theme.color("fg-faint"))
            }
            Text(candidate.ggID ?? "no GG-ID")
                .font(scale.caption.font(weight: .regular, design: .monospaced))
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
