import SwiftUI

struct NewRunScriptDialog: View {
    static let defaultOnExit = RunScriptOnExit.keep

    @Bindable var state: AppState
    let presentation: RunScriptCreationPresentation

    @State private var name = ""
    @State private var onExit = Self.defaultOnExit
    @State private var errorMessage: String?
    @Environment(\.theme) private var theme

    var body: some View {
        DialogContainer(
            title: "New run script",
            subtitle: presentation.subtitle,
            content: {
                DialogField(label: "Script name") {
                    AlasField(
                        text: $name,
                        placeholder: "Dev Server",
                        focusOnAppear: true,
                        onSubmit: submit
                    )
                }
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
                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                }
            },
            cancelTitle: "Cancel",
            confirmTitle: "Create script",
            confirmStyle: .primary,
            onCancel: state.cancelPendingRunScriptCreation,
            onConfirm: submit,
            confirmEnabled: Self.canCreate(name: name)
        )
        .onChange(of: name) { _, _ in
            errorMessage = nil
        }
    }

    nonisolated static func canCreate(name: String) -> Bool {
        RunScriptCreator.normalizedName(name) != nil
    }

    private func submit() {
        guard Self.canCreate(name: name) else { return }
        do {
            try state.createPendingRunScript(name: name, onExit: onExit)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
