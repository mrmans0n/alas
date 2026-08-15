import SwiftUI

struct AttachIssuePresentation: Identifiable {
    let id = UUID()
    let draft: AttachedIssueDraft?
}

struct AttachIssueDialog: View {
    let onCancel: () -> Void
    let onAttach: (AttachedIssueDraft) -> Void

    @State private var model: AttachIssueDialogModel
    @State private var autocomplete: IssueAutocompleteModel
    @Environment(\.theme) private var theme

    init(
        environment: AttachIssueDialogModel.Environment,
        initialDraft: AttachedIssueDraft? = nil,
        onCancel: @escaping () -> Void,
        onAttach: @escaping (AttachedIssueDraft) -> Void
    ) {
        _model = State(initialValue: AttachIssueDialogModel(environment: environment, initialDraft: initialDraft))
        _autocomplete = State(initialValue: IssueAutocompleteModel(load: environment.loadSuggestions))
        self.onCancel = onCancel
        self.onAttach = onAttach
    }

    var body: some View {
        switch model.phase {
        case .entry, .resolving:
            entrySheet
        case .confirmation:
            confirmationSheet
        }
        .onChange(of: model.phase) { _, phase in
            guard phase != .entry else { return }
            autocomplete.dismiss()
            autocomplete.cancelInFlightLoad()
        }
        .onDisappear {
            autocomplete.dismiss()
            autocomplete.cancelInFlightLoad()
        }
    }

    private var entrySheet: some View {
        DialogContainer(
            title: "Attach issue",
            subtitle: "Resolve an issue and prepare the first Chat prompt.",
            content: {
                DialogField(label: "Issue link") {
                    IssueAutocompleteField(
                        text: autocompleteReferenceBinding,
                        state: autocomplete.state,
                        suggestions: autocomplete.filteredSuggestions,
                        selectedIndex: autocomplete.selectedIndex,
                        isPresented: autocomplete.isPresented,
                        focusOnAppear: true,
                        isEnabled: model.phase != .resolving,
                        onTextChange: { reference in
                            model.reference = reference
                            autocomplete.referenceChanged(reference, projectID: model.autocompleteProjectID)
                        },
                        onSubmit: resolve,
                        onMoveSelection: autocomplete.moveSelection,
                        onAcceptSelection: {
                            guard let accepted = autocomplete.acceptSelection() else { return }
                            model.reference = accepted
                        },
                        onDismiss: autocomplete.dismiss,
                        onFocusLost: autocomplete.dismiss
                    )
                }
                if model.phase == .resolving {
                    HStack(spacing: 8) {
                        Spinner(lineWidth: 1.5, duration: 0.7)
                            .frame(width: 14, height: 14)
                        Text("Resolving issue…")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.color("fg-dim"))
                    }
                    .accessibilityElement(children: .combine)
                }
                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.canContinueManually {
                    AlasButton(title: "Continue manually", style: .normal) {
                        Task { await model.continueManually() }
                    }
                    .disabled(model.phase != .entry)
                }
            },
            cancelTitle: "Cancel",
            confirmTitle: model.phase == .resolving ? "Resolving…" : "Resolve issue",
            confirmStyle: .primary,
            onCancel: onCancel,
            onConfirm: resolve,
            confirmEnabled: model.phase == .entry
                && !model.reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
        .interactiveDismissDisabled(model.phase == .resolving)
        .onAppear {
            autocomplete.referenceChanged(model.reference, projectID: model.autocompleteProjectID)
        }
    }

    private var confirmationSheet: some View {
        DialogContainer(
            title: "Attach issue",
            subtitle: "Resolve an issue and prepare the first Chat prompt.",
            width: DialogContainerLayout.projectWidth,
            content: {
                if let source = model.resolved?.source {
                    VStack(alignment: .leading, spacing: 5) {
                        Text([source.providerLabel, source.displayReference].compactMap { $0 }.joined(separator: " "))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(theme.color("fg"))
                        Text(source.canonicalURL.absoluteString)
                            .font(.system(size: 11))
                            .foregroundColor(theme.color("fg-dim"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.color("bg-0"))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(theme.color("line"), lineWidth: 0.5)
                    )
                }
                DialogField(label: "Title") {
                    AlasField(text: Bindable(model).title)
                }
                DialogField(label: "Issue context") {
                    textEditor(text: Bindable(model).context, minHeight: 90, maxHeight: 150)
                }
                DialogField(label: "Initial prompt") {
                    textEditor(text: promptBinding, minHeight: 130, maxHeight: 190)
                }
            },
            cancelTitle: "Back",
            confirmTitle: "Attach",
            confirmStyle: .primary,
            onCancel: model.cancelResolution,
            onConfirm: attach,
            confirmEnabled: model.makeDraft() != nil
        )
    }

    private var promptBinding: Binding<String> {
        Binding(
            get: { model.prompt },
            set: { model.setPrompt($0) }
        )
    }

    private var autocompleteReferenceBinding: Binding<String> {
        Binding(
            get: { model.reference },
            set: { reference in
                model.reference = reference
                autocomplete.referenceChanged(reference, projectID: model.autocompleteProjectID)
            }
        )
    }

    private func textEditor(text: Binding<String>, minHeight: CGFloat, maxHeight: CGFloat) -> some View {
        TextEditor(text: text)
            .font(.system(size: 12))
            .foregroundColor(theme.color("fg"))
            .scrollContentBackground(.hidden)
            .frame(minHeight: minHeight, maxHeight: maxHeight)
            .padding(8)
            .background(theme.color("bg-0"))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(theme.color("line"), lineWidth: 0.5)
            )
    }

    private func resolve() {
        autocomplete.dismiss()
        autocomplete.cancelInFlightLoad()
        Task { await model.resolve() }
    }

    private func attach() {
        guard let draft = model.makeDraft() else { return }
        onAttach(draft)
    }
}
