import SwiftUI

struct ShortcutsPane: View {
    @Bindable var state: AppState
    @Environment(\.theme) var theme
    @State private var searchText = ""
    @State private var recordingAction: ShortcutAction?
    @State private var liveModifiers: [ShortcutBinding.Modifier] = []
    @State private var justModifiedAction: ShortcutAction?
    @State private var pendingConflict: PendingConflict?
    @State private var showResetAllConfirm = false
    @State private var recorder: ShortcutRecorderSession?

    private struct PendingConflict: Equatable {
        let action: ShortcutAction
        let conflictingWith: ShortcutAction
        let candidate: ShortcutBinding
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Shortcuts").font(.system(size: 18, weight: .semibold))
                Text("Customize keyboard shortcuts. Click a chip and press a new combo.")
                    .font(.system(size: 12.5))
                    .foregroundColor(theme.color("fg-dim"))
                    .padding(.bottom, 12)

                searchField

                ForEach(ShortcutGroup.allCases, id: \.self) { group in
                    let actions = visibleActions(in: group)
                    if !actions.isEmpty {
                        SettingsGroup(title: group.label) {
                            ForEach(actions, id: \.self) { action in
                                row(for: action)
                            }
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button("Reset all to defaults") { showResetAllConfirm = true }
                        .buttonStyle(.borderless)
                        .foregroundColor(theme.color("fg-muted"))
                }
                .padding(.top, 16)
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
        }
        .onDisappear { stopRecorder() }
        .confirmationDialog(
            "Reset all \(ShortcutAction.allCases.count) shortcuts to their defaults? This will clear your overrides.",
            isPresented: $showResetAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset all", role: .destructive) { state.resetAllShortcuts() }
            Button("Cancel", role: .cancel) { }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg-faint"))
            TextField("Search…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(theme.color("bg-3"))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func row(for action: ShortcutAction) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingsRow(name: action.label, desc: action.description) {
                ShortcutChip(
                    binding: state.binding(for: action),
                    isRecording: recordingAction == action,
                    justModified: justModifiedAction == action,
                    liveModifiers: recordingAction == action ? liveModifiers : [],
                    onClick: { startRecording(for: action) },
                    onClear: { state.setShortcut(nil, for: action) }
                )
            }
            .contextMenu {
                Button("Reset to default") { state.resetShortcut(for: action) }
            }
            if let pending = pendingConflict, pending.action == action {
                conflictBanner(pending: pending)
            }
        }
    }

    @ViewBuilder
    private func conflictBanner(pending: PendingConflict) -> some View {
        HStack(spacing: 10) {
            (Text("\(pending.candidate.displayString) is already bound to ")
                .foregroundColor(theme.color("fg-muted"))
             + Text(pending.conflictingWith.label).bold().foregroundColor(theme.color("fg")))
            Spacer()
            Button("Reassign") {
                state.setShortcut(nil, for: pending.conflictingWith)
                state.setShortcut(pending.candidate, for: pending.action)
                flashJustModified(pending.action)
                pendingConflict = nil
            }
            .buttonStyle(.borderedProminent)
            Button("Cancel") { pendingConflict = nil }
                .buttonStyle(.borderless)
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 10).padding(.vertical, 6)
        // "danger-soft" is not a theme token; use del at low opacity (same
        // pattern as InlineErrorStrip).
        .background(theme.color("del").opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    // MARK: - Filtering

    private func visibleActions(in group: ShortcutGroup) -> [ShortcutAction] {
        let inGroup = ShortcutAction.allCases.filter { $0.group == group }
        guard !searchText.isEmpty else { return inGroup }
        let q = searchText.lowercased()
        // Normalize spaces so typing "⌘P" matches the displayed "⌘ P".
        let qStripped = q.replacingOccurrences(of: " ", with: "")
        return inGroup.filter { action in
            if action.label.lowercased().contains(q) { return true }
            if group.label.lowercased().contains(q) { return true }
            if let b = state.binding(for: action) {
                let display = b.displayString.lowercased()
                if display.contains(q) { return true }
                if display.replacingOccurrences(of: " ", with: "").contains(qStripped) {
                    return true
                }
            }
            return false
        }
    }

    // MARK: - Recording

    private func startRecording(for action: ShortcutAction) {
        pendingConflict = nil
        recordingAction = action
        liveModifiers = []
        recorder?.stop()
        let session = ShortcutRecorderSession(
            onCapture: { binding in handleCapture(binding, for: action) },
            onCancel: { cancelRecording() },
            onFlagsChanged: { mods in liveModifiers = mods }
        )
        session.start()
        recorder = session
    }

    private func handleCapture(_ binding: ShortcutBinding, for action: ShortcutAction) {
        switch ShortcutRecorder.validate(binding) {
        case .needsModifier, .reserved:
            // Stay in recording state; the user can try again or press Esc.
            return
        case .ok:
            stopRecorder()
            if let conflict = state.conflict(for: binding, excluding: action) {
                pendingConflict = PendingConflict(
                    action: action,
                    conflictingWith: conflict,
                    candidate: binding
                )
            } else {
                state.setShortcut(binding, for: action)
                flashJustModified(action)
            }
            recordingAction = nil
            liveModifiers = []
        }
    }

    private func cancelRecording() {
        stopRecorder()
        recordingAction = nil
        liveModifiers = []
    }

    private func stopRecorder() {
        recorder?.stop()
        recorder = nil
    }

    private func flashJustModified(_ action: ShortcutAction) {
        justModifiedAction = action
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            if justModifiedAction == action { justModifiedAction = nil }
        }
    }
}
