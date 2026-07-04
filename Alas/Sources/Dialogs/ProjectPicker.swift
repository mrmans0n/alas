import SwiftUI

struct ProjectPicker: View {
    @Binding var selection: String
    let projects: [ProjectConfig]

    @Environment(\.theme) var theme
    @State private var open = false
    @State private var search = ""

    private var selectedProject: ProjectConfig? {
        projects.first { $0.id == selection }
    }

    private var filteredProjects: [ProjectConfig] {
        Self.filteredProjects(projects, search: search)
    }

    var body: some View {
        Button(action: { open.toggle() }) {
            HStack(spacing: 6) {
                if let project = selectedProject {
                    ProjectIconView(icon: project.icon, fallbackName: project.name, size: .picker)
                }
                Text(selectedProject?.name ?? "Choose a repository")
                    .font(.system(size: 12))
                    .foregroundColor(theme.color("fg"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(theme.color("fg-dim"))
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(theme.color("bg-1"))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(theme.color("line"), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            popoverBody
        }
    }

    @ViewBuilder
    private var popoverBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            AlasField(text: $search, placeholder: "Search repositories...")
                .padding(8)

            Divider().background(theme.color("line"))

            if projects.isEmpty {
                Text("No repositories")
                    .font(.system(size: 12))
                    .foregroundColor(theme.color("fg-dim"))
                    .padding(12)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredProjects) { project in
                            row(project: project)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 320)
    }

    private func row(project: ProjectConfig) -> some View {
        Button(action: {
            selection = project.id
            open = false
        }) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.color("fg"))
                    .opacity(project.id == selection ? 1 : 0)
                ProjectIconView(icon: project.icon, fallbackName: project.name, size: .picker)
                Text(project.name)
                    .font(.system(size: 12))
                    .foregroundColor(theme.color("fg"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    nonisolated static func filteredProjects(
        _ projects: [ProjectConfig],
        search: String
    ) -> [ProjectConfig] {
        if search.isEmpty { return projects }
        return projects.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }
}
