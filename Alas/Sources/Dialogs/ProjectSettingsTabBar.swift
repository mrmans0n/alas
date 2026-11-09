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
    @Environment(\.designScale) private var scale
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
                                    .font(.system(size: 16)) // design-literal: tab icon, not text
                            }
                        }
                        .frame(width: 20, height: 20)
                        .accessibilityHidden(true)
                        Text(tab.rawValue)
                            .font(scale.meta.font(weight: .medium))
                    }
                    .foregroundStyle(theme.color(selection == tab ? "fg" : "fg-dim"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, scale.space[3])
                    .padding(.vertical, scale.space[3])
                    .contentShape(Rectangle())
                    .background {
                        if selection == tab {
                            RoundedRectangle(cornerRadius: scale.radius.medium)
                                .fill(theme.color("bg-3"))
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(scale.space[3])
        .frame(width: 172)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(theme.color("bg-2"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Project settings sections")
    }
}
