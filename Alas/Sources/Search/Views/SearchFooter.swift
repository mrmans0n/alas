import SwiftUI

/// Bottom hint row showing keyboard affordances. Phase 1 ships only the
/// three honored hints: open, mode-toggle (hidden when content tab is
/// not yet rendered), close. The mode-toggle is added in Phase 2.
struct SearchFooter: View {
    @Bindable var model: SearchModel
    let showsKindToggle: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 5) {
                SearchKbd(label: "↵")
                Text("open").font(.system(size: 10.5))
                    .foregroundColor(theme.color("fg-faint"))
            }
            if showsKindToggle {
                HStack(spacing: 5) {
                    SearchKbd(label: "⇥")
                    Text(model.kind == .files ? "content" : "files")
                        .font(.system(size: 10.5))
                        .foregroundColor(theme.color("fg-faint"))
                }
            }
            HStack(spacing: 5) {
                SearchKbd(label: "esc")
                Text("close").font(.system(size: 10.5))
                    .foregroundColor(theme.color("fg-faint"))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(theme.color("bg-2").opacity(0.5))
        .overlay(
            Rectangle()
                .fill(theme.color("line-soft"))
                .frame(height: 0.5),
            alignment: .top
        )
    }
}
