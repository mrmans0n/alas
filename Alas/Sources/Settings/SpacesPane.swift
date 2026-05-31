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
    @State private var nameDraft: String
    @State private var emojiDraft: String
    @State private var isConfirmingDelete = false

    init(state: AppState, space: SpaceConfig, canDelete: Bool) {
        self.state = state
        self.space = space
        self.canDelete = canDelete
        _nameDraft = State(initialValue: space.name)
        _emojiDraft = State(initialValue: space.emoji)
    }

    var body: some View {
        SettingsRow(name: space.name, desc: "Customize this space.") {
            HStack(spacing: 8) {
                AlasField(text: $nameDraft, onSubmit: applyChanges)
                    .frame(width: 180)
                    .accessibilityLabel("Space name for \(space.name)")
                AlasField(text: $emojiDraft, onSubmit: applyChanges)
                    .frame(width: 48)
                    .accessibilityLabel("Space emoji for \(space.name)")
                AlasButton(title: "Apply", icon: "checkmark", style: .normal, action: applyChanges)
                    .disabled(!hasDraftChanges)
                AlasButton(title: "Delete", icon: "trash", style: .normal) {
                    isConfirmingDelete = true
                }
                .disabled(!canDelete)
                .accessibilityLabel("Delete space \(space.name)")
            }
        }
        .confirmationDialog(
            "Delete \(space.name)?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Space", role: .destructive) {
                state.deleteSpace(id: space.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Repos and files will not be deleted. Only this space organization will be removed.")
        }
        .onChange(of: space.name) { oldName, newName in
            guard nameDraft == oldName else { return }
            nameDraft = newName
        }
        .onChange(of: space.emoji) { oldEmoji, newEmoji in
            guard emojiDraft == oldEmoji else { return }
            emojiDraft = newEmoji
        }
    }

    private var hasDraftChanges: Bool {
        nameDraft != (state.spacesManager.space(id: space.id)?.name ?? space.name)
            || emojiDraft != (state.spacesManager.space(id: space.id)?.emoji ?? space.emoji)
    }

    private func applyChanges() {
        let committedEmoji = String(emojiDraft.prefix(1))
        state.updateSpace(id: space.id, name: nameDraft, emoji: committedEmoji)
        if let updated = state.spacesManager.space(id: space.id) {
            nameDraft = updated.name
            emojiDraft = updated.emoji
        }
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
