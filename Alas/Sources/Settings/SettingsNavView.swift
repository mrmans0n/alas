import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, worktrees, terminal, code, appearance
    var id: String { rawValue }
    var label: String {
        switch self {
        case .general:    return "General"
        case .worktrees:  return "Worktrees"
        case .terminal:   return "Terminal"
        case .code:       return "Code"
        case .appearance: return "Appearance"
        }
    }
    var icon: String {
        switch self {
        case .general:    return "gear"
        case .worktrees:  return "branch"
        case .terminal:   return "terminal"
        case .code:       return "code"
        case .appearance: return "palette"
        }
    }
}

struct SettingsNavView: View {
    @Binding var selection: SettingsSection
    @Environment(\.theme) var theme

    var body: some View {
        VStack(spacing: 1) {
            ForEach(SettingsSection.allCases) { section in
                Button { selection = section } label: {
                    HStack(spacing: 9) {
                        Icon(name: section.icon, size: 14,
                             color: selection == section ? theme.color("accent") : theme.color("fg-dim"))
                            .frame(width: 16, height: 16)
                        Text(section.label).font(.system(size: 12.5))
                            .foregroundColor(selection == section ? theme.color("fg") : theme.color("fg-muted"))
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(selection == section ? theme.color("accent-soft") : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text("Alas 0.5.0")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(theme.color("fg-faint"))
                .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .padding(.horizontal, 8).padding(.vertical, 12)
        .frame(width: 200)
        .background(theme.color("bg-2"))
        .overlay(Divider().opacity(0.5), alignment: .trailing)
    }
}
