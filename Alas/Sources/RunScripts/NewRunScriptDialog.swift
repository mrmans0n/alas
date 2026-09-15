import SwiftUI

/// What the new-script dialog starts from: an empty file the user names, or
/// a stack template that writes a bundle of ready-to-run scripts.
enum RunScriptDialogStart: Hashable {
    case blank
    case stack(RunScriptStack)
}

struct NewRunScriptDialog: View {
    static let defaultOnExit = RunScriptOnExit.keep

    @Bindable var state: AppState
    let presentation: RunScriptCreationPresentation

    @State private var start: RunScriptDialogStart
    @State private var checkedActionIDs: Set<String>
    @State private var name = ""
    @State private var onExit = Self.defaultOnExit
    @State private var errorMessage: String?
    @State private var wantsWritingHelp = false
    @State private var writingHelpRequest = ""
    @Environment(\.theme) private var theme

    init(state: AppState, presentation: RunScriptCreationPresentation) {
        _state = Bindable(wrappedValue: state)
        self.presentation = presentation
        let start = Self.initialStart(scope: presentation.scope, detections: presentation.detectedStacks)
        _start = State(initialValue: start)
        _checkedActionIDs = State(initialValue: Self.defaultCheckedActionIDs(
            start: start, detections: presentation.detectedStacks
        ))
    }

    var body: some View {
        DialogContainer(
            title: "New run script",
            subtitle: presentation.subtitle,
            content: {
                if presentation.scope == .repo {
                    DialogField(label: "Start from") {
                        startPicker
                    }
                }
                if let stack = selectedStack {
                    DialogField(label: "Scripts") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(stackActions(for: stack)) { action in
                                actionRow(action)
                            }
                        }
                    }
                } else {
                    DialogField(label: "Script name") {
                        AlasField(
                            text: $name,
                            placeholder: "Dev Server",
                            focusOnAppear: true,
                            onSubmit: submit
                        )
                    }
                }
                // Template scripts carry their own exit behavior: servers keep
                // the pane, one-shot commands close it. Only a blank script
                // needs to ask.
                if selectedStack == nil {
                    DialogField(label: "When script exits") {
                        HStack(spacing: 0) {
                            AlasSegmentedControl(
                                selection: onExit,
                                options: [
                                    AlasSegmentedOption(id: .keep, label: "Keep pane open"),
                                    AlasSegmentedOption(id: .close, label: "Close pane"),
                                ],
                                onSelect: {
                                    onExit = $0
                                    errorMessage = nil
                                }
                            )
                            Spacer(minLength: 0)
                        }
                    }
                    Toggle("Help me write this", isOn: $wantsWritingHelp)
                        .toggleStyle(.checkbox)
                    if wantsWritingHelp {
                        RunScriptWritingHelpField(request: $writingHelpRequest)
                    }
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                }
            },
            cancelTitle: "Cancel",
            confirmTitle: Self.confirmTitle(
                start: start, selectedCount: checkedActionIDs.count, wantsWritingHelp: wantsWritingHelp
            ),
            confirmStyle: .primary,
            onCancel: state.cancelPendingRunScriptCreation,
            onConfirm: submit,
            confirmEnabled: canSubmit
        )
        .onChange(of: name) { _, _ in
            errorMessage = nil
        }
        .onChange(of: wantsWritingHelp) { _, _ in
            errorMessage = nil
        }
        .onChange(of: start) { _, newValue in
            checkedActionIDs = Self.defaultCheckedActionIDs(start: newValue, detections: presentation.detectedStacks)
            errorMessage = nil
        }
    }

    // MARK: - Pure helpers (unit-tested)

    nonisolated static func canCreate(name: String) -> Bool {
        RunScriptCreator.normalizedName(name) != nil
    }

    /// Repo scripts default to the first detected stack; global scripts are
    /// always blank because templates are repository-specific.
    nonisolated static func initialStart(
        scope: RunScriptScope,
        detections: [RunScriptStackDetection]
    ) -> RunScriptDialogStart {
        guard scope == .repo, let first = detections.first else { return .blank }
        return .stack(first.stack)
    }

    /// Detected stacks first, in catalog order, then everything else.
    nonisolated static func orderedStacks(
        detections: [RunScriptStackDetection]
    ) -> (detected: [RunScriptStack], others: [RunScriptStack]) {
        let detected = detections.map(\.stack)
        return (detected, RunScriptStack.allCases.filter { !detected.contains($0) })
    }

    nonisolated static func context(
        for stack: RunScriptStack,
        detections: [RunScriptStackDetection]
    ) -> RunScriptStackContext {
        detections.first { $0.stack == stack }?.context ?? RunScriptStackContext()
    }

    nonisolated static func defaultCheckedActionIDs(
        start: RunScriptDialogStart,
        detections: [RunScriptStackDetection]
    ) -> Set<String> {
        guard case .stack(let stack) = start else { return [] }
        let actions = RunScriptStackCatalog.actions(for: stack, context: context(for: stack, detections: detections))
        return Set(actions.filter(\.isCheckedByDefault).map(\.id))
    }

    nonisolated static func confirmTitle(
        start: RunScriptDialogStart,
        selectedCount: Int,
        wantsWritingHelp: Bool
    ) -> String {
        switch start {
        case .blank:
            wantsWritingHelp ? "Create script and open chat" : "Create script"
        case .stack:
            selectedCount == 1 ? "Create 1 script" : "Create \(selectedCount) scripts"
        }
    }

    // MARK: - Views

    private var startPicker: some View {
        let stacks = Self.orderedStacks(detections: presentation.detectedStacks)
        return Picker("", selection: $start) {
            ForEach(stacks.detected) { stack in
                Text("\(stack.displayName) · detected").tag(RunScriptDialogStart.stack(stack))
            }
            if !stacks.detected.isEmpty {
                Divider()
            }
            ForEach(stacks.others) { stack in
                Text(stack.displayName).tag(RunScriptDialogStart.stack(stack))
            }
            Divider()
            Text("Blank script").tag(RunScriptDialogStart.blank)
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel("Start from")
    }

    private func actionRow(_ action: RunScriptStackAction) -> some View {
        Toggle(isOn: Binding(
            get: { checkedActionIDs.contains(action.id) },
            set: { checked in
                if checked { checkedActionIDs.insert(action.id) } else { checkedActionIDs.remove(action.id) }
                errorMessage = nil
            }
        )) {
            HStack(spacing: 8) {
                Text(action.displayName)
                    .font(.system(size: 12))
                Text(Self.commandPreview(for: action))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.color("fg-dim"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if action.onExit == .keep {
                    Text("keeps pane")
                        .font(.system(size: 10))
                        .foregroundColor(theme.color("fg-dim"))
                }
            }
        }
        .toggleStyle(.checkbox)
    }

    /// The command line a script runs, without any leading comment lines.
    nonisolated static func commandPreview(for action: RunScriptStackAction) -> String {
        action.body
            .split(separator: "\n")
            .last { !$0.hasPrefix("#") }
            .map(String.init) ?? action.body
    }

    // MARK: - Submit

    private var selectedStack: RunScriptStack? {
        if case .stack(let stack) = start { return stack }
        return nil
    }

    private func stackActions(for stack: RunScriptStack) -> [RunScriptStackAction] {
        RunScriptStackCatalog.actions(
            for: stack, context: Self.context(for: stack, detections: presentation.detectedStacks)
        )
    }

    private func submit() {
        guard canSubmit else { return }
        do {
            if let stack = selectedStack {
                let actions = stackActions(for: stack).filter { checkedActionIDs.contains($0.id) }
                try state.createPendingRunScripts(stack: stack, actions: actions)
            } else {
                try state.createPendingRunScript(
                    name: name, onExit: onExit,
                    writingHelpRequest: wantsWritingHelp ? writingHelpRequest : nil
                )
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var canSubmit: Bool {
        if selectedStack != nil {
            return !checkedActionIDs.isEmpty
        }
        return Self.canCreate(name: name)
            && (!wantsWritingHelp || !writingHelpRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
