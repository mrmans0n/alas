import SwiftUI

struct SearchEmptyState: View {
    @Bindable var model: SearchModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .light))
                .foregroundColor(theme.color("fg-faint"))
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.color("fg-dim"))
                .padding(.top, 4)
            Text(subtitle)
                .font(.system(size: 11.5))
                .foregroundColor(theme.color("fg-faint"))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 60)
        .padding(.horizontal, 30)
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
