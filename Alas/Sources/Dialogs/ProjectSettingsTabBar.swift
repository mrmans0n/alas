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

struct ProjectSettingsTabBar: View {
    @Binding var selection: ProjectSettingsTab
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 22) {
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
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(theme.color("accent"))
                            .frame(height: 2)
                            .opacity(selection == tab ? 1 : 0)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .background(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Project settings tabs")
    }
}
