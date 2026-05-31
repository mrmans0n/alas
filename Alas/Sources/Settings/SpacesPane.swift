import SwiftUI

struct SpacesPane: View {
    @Bindable var state: AppState
    @Environment(\.theme) var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Spaces")
                    .font(.system(size: 18, weight: .semibold))
                Text("Organize sidebar repositories into focused groups.")
                    .font(.system(size: 12.5))
                    .foregroundColor(theme.color("fg-dim"))
                    .padding(.bottom, 12)

                SettingsGroup(title: "Spaces") {
                    ForEach(state.spacesManager.spaces) { space in
                        SpaceSettingsRow(
                            state: state,
                            space: space,
                            canDelete: state.spacesManager.spaces.count > 1
                        )
                    }
                    SettingsRow(name: "Add space", desc: "Create another sidebar group.") {
                        AlasButton(title: "New Space", icon: "plus", style: .normal) {
                            state.addSpace(name: "New Space", emoji: "✨")
                        }
                    }
                }

                SettingsGroup(title: "Membership") {
                    ForEach(state.projects) { project in
                        ProjectSpaceMembershipRow(state: state, project: project)
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
        }
    }
}

private struct SpaceSettingsRow: View {
    @Bindable var state: AppState
    let space: SpaceConfig
    let canDelete: Bool

    var body: some View {
        SettingsRow(name: space.name, desc: "Customize this space.") {
            HStack(spacing: 8) {
                AlasField(text: nameBinding)
                    .frame(width: 180)
                AlasField(text: emojiBinding)
                    .frame(width: 48)
                AlasButton(title: "Delete", icon: "trash", style: .normal) {
                    state.deleteSpace(id: space.id)
                }
                .disabled(!canDelete)
            }
        }
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { state.spacesManager.space(id: space.id)?.name ?? space.name },
            set: { state.renameSpace(id: space.id, name: $0) }
        )
    }

    private var emojiBinding: Binding<String> {
        Binding(
            get: { state.spacesManager.space(id: space.id)?.emoji ?? space.emoji },
            set: { state.setSpaceEmoji(id: space.id, emoji: String($0.prefix(1))) }
        )
    }
}

private struct ProjectSpaceMembershipRow: View {
    @Bindable var state: AppState
    let project: ProjectConfig

    var body: some View {
        SettingsRow(name: project.name, desc: project.path) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(state.spacesManager.spaces) { space in
                    let isMember = state.spacesManager.space(id: space.id)?.projectIds.contains(project.id) == true
                    Toggle(isOn: membershipBinding(spaceId: space.id)) {
                        Text("\(space.emoji) \(space.name)")
                            .lineLimit(1)
                    }
                    .toggleStyle(.checkbox)
                    .disabled(isMember && state.spacesManager.membershipCount(forProject: project.id) == 1)
                }
            }
        }
    }

    private func membershipBinding(spaceId: String) -> Binding<Bool> {
        Binding(
            get: { isProjectMember(of: spaceId) },
            set: { newValue in
                guard newValue != isProjectMember(of: spaceId) else { return }
                state.toggleProject(projectId: project.id, inSpace: spaceId)
            }
        )
    }

    private func isProjectMember(of spaceId: String) -> Bool {
        state.spacesManager.space(id: spaceId)?.projectIds.contains(project.id) == true
    }
}
