import SwiftUI
import AppKit

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
                    SettingsRow(name: "Show single space", desc: "Keep the sidebar space indicator visible when only one space exists.") {
                        AlasToggle(on: Binding(
                            get: { state.spacesManager.showSingleSpaceAffordance },
                            set: { state.setShowSingleSpaceAffordance($0) }
                        ))
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
                SpaceIconPickerButton(selection: emojiDraft) { icon in
                    emojiDraft = icon
                    applyChanges()
                }
                .accessibilityLabel("Space icon for \(space.name)")
                SpaceRowIconButton(icon: "checkmark", tooltip: "Apply changes", action: applyChanges)
                    .disabled(!hasDraftChanges)
                    .accessibilityLabel("Apply changes to \(space.name) space")
                SpaceRowIconButton(icon: "trash", tooltip: "Delete space") {
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
        let committedEmoji = SpaceIcon.sanitized(emojiDraft, fallback: space.emoji)
        state.updateSpace(id: space.id, name: nameDraft, emoji: committedEmoji)
        if let updated = state.spacesManager.space(id: space.id) {
            nameDraft = updated.name
            emojiDraft = updated.emoji
        }
    }
}

private struct SpaceRowIconButton: View {
    let icon: String
    let tooltip: String
    let action: () -> Void
    @Environment(\.theme) var theme

    var body: some View {
        Button(action: action) {
            Icon(name: icon, size: 11, color: theme.color("fg"))
                .frame(width: 28, height: 28)
                .background(theme.color("bg-3"))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(theme.color("line"), lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }
}

private struct SpaceIconPickerButton: View {
    let selection: String
    let onSelect: (String) -> Void
    @Environment(\.theme) var theme

    var body: some View {
        SpaceEmojiPickerControl(selection: selection, onSelect: onSelect)
            .frame(width: 34, height: 28)
            .background(theme.color("bg-1"))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(theme.color("line"), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .fixedSize()
    }
}

private struct SpaceEmojiPickerControl: NSViewRepresentable {
    let selection: String
    let onSelect: (String) -> Void

    func makeNSView(context: Context) -> BackingView {
        let view = BackingView()
        view.onSelect = onSelect
        return view
    }

    func updateNSView(_ nsView: BackingView, context: Context) {
        nsView.button.title = selection
        nsView.onSelect = onSelect
    }

    final class BackingView: NSView, NSTextFieldDelegate {
        var onSelect: ((String) -> Void)?
        let button = NSButton()
        private let input = NSTextField()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)

            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.setButtonType(.momentaryPushIn)
            button.font = NSFont.systemFont(ofSize: 15)
            button.target = self
            button.action = #selector(openCharacterPalette)
            addSubview(button)

            input.isBordered = false
            input.isBezeled = false
            input.drawsBackground = false
            input.focusRingType = .none
            input.alphaValue = 0.01
            input.font = NSFont.systemFont(ofSize: 15)
            input.delegate = self
            addSubview(input)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layout() {
            super.layout()
            button.frame = bounds
            input.frame = NSRect(x: bounds.minX, y: bounds.minY, width: 1, height: 1)
        }

        @objc func openCharacterPalette() {
            input.stringValue = ""
            window?.makeFirstResponder(input)
            NSApp.orderFrontCharacterPalette(nil)
        }

        func controlTextDidChange(_ obj: Notification) {
            commit(input.stringValue)
        }

        private func commit(_ rawValue: String) {
            guard SpaceEmojiPickerSelection.commit(
                rawValue,
                onSelect: { [weak self] icon in
                    self?.input.stringValue = ""
                    self?.onSelect?(icon)
                },
                dismissPicker: { [weak self] in
                    SpaceEmojiPickerWindowDismissal.dismiss(excluding: self?.window)
                }
            ) else { return }
            input.stringValue = ""
            window?.makeFirstResponder(button)
            window?.makeKeyAndOrderFront(nil)
        }
    }
}

enum SpaceEmojiPickerSelection {
    @discardableResult
    static func commit(
        _ rawValue: String,
        onSelect: (String) -> Void,
        dismissPicker: () -> Void
    ) -> Bool {
        let icon = SpaceIcon.sanitized(rawValue, fallback: "")
        guard !icon.isEmpty else { return false }

        onSelect(icon)
        dismissPicker()
        return true
    }
}

enum SpaceEmojiPickerWindowDismissal {
    @MainActor
    static func dismiss(excluding ownerWindow: NSWindow?) {
        for window in NSApp.windows where window !== ownerWindow && window.isVisible && isCharacterPalette(window) {
            window.orderOut(nil)
        }
    }

    private static func isCharacterPalette(_ window: NSWindow) -> Bool {
        let className = String(describing: type(of: window)).lowercased()
        let title = window.title.lowercased()

        return className.contains("character")
            || className.contains("emoji")
            || title.contains("character")
            || title.contains("emoji")
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
                    .accessibilityLabel("Include \(project.name) in \(space.name) space")
                    .accessibilityValue(isMember ? "included" : "not included")
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
