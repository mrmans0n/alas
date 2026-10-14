import SwiftUI

enum ProjectSettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case agents = "Agents"
    case automation = "Automation"
    case integrations = "Integrations"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .general: "folder"
        case .agents: "cpu"
        case .automation: "terminal"
        case .integrations: ""
        }
    }
}

struct ProjectSettingsSidebar: View {
    @Binding var selection: ProjectSettingsTab
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(ProjectSettingsTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    HStack(spacing: 6) {
                        Group {
                            if tab == .integrations {
                                Image("MCPLogo")
                                    .renderingMode(.template)
                                    .resizable()
                                    .scaledToFit()
                            } else {
                                Image(systemName: tab.symbol)
                                    .font(.system(size: 16))
                            }
                        }
                        .frame(width: 20, height: 20)
                        .accessibilityHidden(true)
                        Text(tab.rawValue)
                            .font(.system(size: 12.5, weight: .medium))
                    }
                    .foregroundStyle(theme.color(selection == tab ? "fg" : "fg-dim"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                    .background {
                        if selection == tab {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(theme.color("bg-3"))
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 172)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(theme.color("bg-2"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Project settings sections")
    }
}
