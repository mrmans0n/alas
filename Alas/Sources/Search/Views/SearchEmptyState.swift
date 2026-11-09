import SwiftUI

struct SearchEmptyState: View {
    @Bindable var model: SearchModel
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .light)) // design-literal: empty-state icon
                .foregroundColor(theme.color("fg-faint"))
            Text(title)
                .font(scale.emphasisFont)
                .foregroundColor(theme.color("fg-dim"))
                .padding(.top, scale.space[1])
            Text(subtitle)
                .font(scale.metaFont)
                .foregroundColor(theme.color("fg-faint"))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 60) // design-literal: empty-state breathing room
        .padding(.horizontal, scale.space[5])
    }

    private var title: String {
        if !model.trimmedQuery.isEmpty { return "No matches" }
        switch model.kind {
        case .files:   return "Recent files"
        case .content: return "Type to search contents"
        }
    }

    private var subtitle: String {
        if !model.trimmedQuery.isEmpty {
            let where_: String
            switch model.scope {
            case .thisWorktree: where_ = "this worktree"
            case .workspaceCheckout: where_ = "this Workspace Checkout"
            case .allRepos:     where_ = "any repo"
            }
            return "Nothing in \(where_) matches \u{201C}\(model.trimmedQuery)\u{201D}."
        }
        switch model.kind {
        case .files:   return "Start typing to fuzzy-match a path."
        case .content: return "Search across all tracked files. Tab to switch back to filenames."
        }
    }
}
