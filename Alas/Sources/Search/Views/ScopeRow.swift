import SwiftUI

struct ScopeRow: View {
    @Bindable var model: SearchModel
    let isThisWorktreeAvailable: Bool
    var isWorkspaceCheckoutAvailable: Bool = false
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Text("SCOPE")
                .font(.system(size: 9.5, weight: .medium))
                .tracking(0.5)
                .foregroundColor(theme.color("fg-faint"))
            HStack(spacing: 3) {
                pill(.thisWorktree, enabled: isThisWorktreeAvailable)
                pill(.workspaceCheckout, enabled: isWorkspaceCheckoutAvailable)
                pill(.allRepos,     enabled: true)
            }
            Spacer(minLength: 0)
            if model.kind == .content {
                HStack(spacing: 2) {
                    optionToggle(
                        glyph: "Aa",
                        isOn: model.contentOptions.caseSensitive,
                        onTap: { model.contentOptions.caseSensitive.toggle() }
                    )
                    optionToggle(
                        glyph: "W",
                        isOn: model.contentOptions.wholeWord,
                        onTap: { model.contentOptions.wholeWord.toggle() }
                    )
                    optionToggle(
                        glyph: ".*",
                        isOn: model.contentOptions.regex,
                        onTap: { model.contentOptions.regex.toggle() }
                    )
                }
            }
            Text(countText)
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundColor(theme.color("fg-faint"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(theme.color("bg-2").opacity(0.4))
        .overlay(
            Rectangle()
                .fill(theme.color("line-soft"))
                .frame(height: 0.5),
            alignment: .bottom
        )
    }

    private func pill(_ scope: SearchScope, enabled: Bool) -> some View {
        let isOn = model.scope == scope
        return Button {
            model.scope = scope
        } label: {
            Text(scope.displayName)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isOn ? theme.color("accent-soft") : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(
                            isOn ? theme.color("accent").opacity(0.35) : Color.clear,
                            lineWidth: 0.5
                        )
                )
                .foregroundColor(
                    enabled
                        ? (isOn ? theme.color("accent") : theme.color("fg-dim"))
                        : theme.color("fg-faint").opacity(0.5)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    @ViewBuilder
    private func optionToggle(glyph: String, isOn: Bool, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            Text(glyph)
                .font(.system(size: 10, design: .monospaced))
                .frame(width: 22, height: 20)
                .foregroundColor(isOn ? theme.color("accent") : theme.color("fg-faint"))
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isOn ? theme.color("accent-soft") : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(
                            isOn ? theme.color("accent").opacity(0.35) : theme.color("line"),
                            lineWidth: 0.5
                        )
                )
        }
        .buttonStyle(.plain)
    }

    private var countText: String {
        let n = model.totalResultRows
        switch model.kind {
        case .files:   return "\(n) \(n == 1 ? "file"  : "files")"
        case .content: return "\(n) \(n == 1 ? "match" : "matches")"
        }
    }
}
