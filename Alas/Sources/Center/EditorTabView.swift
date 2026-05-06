import SwiftUI

struct EditorTabView: View {
    let worktreePath: URL
    let relativePath: String
    let worktreeId: String
    let appState: AppState
    @Environment(\.theme) var theme

    var body: some View {
        VStack(spacing: 0) {
            breadcrumb
            CodeEditorView(
                worktreeId: worktreeId,
                worktreeRoot: worktreePath,
                relativePath: relativePath,
                appState: appState
            )
        }
        .background(theme.color("bg-1"))
    }

    private var breadcrumb: some View {
        let components = relativePath.split(separator: "/")
        let lastIndex = components.count - 1
        return HStack(spacing: 6) {
            ForEach(Array(components.enumerated()), id: \.offset) { (i, comp) in
                Text(comp)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(i == lastIndex ? theme.color("fg") : theme.color("fg-muted"))
                if i < lastIndex {
                    Text("/").foregroundColor(theme.color("fg-faint"))
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12).frame(height: 28)
        .background(theme.color("bg-1"))
        .overlay(Divider().opacity(0.5), alignment: .bottom)
    }
}
