import SwiftUI

struct AttachIssuePresentation: Identifiable {
    let id = UUID()
    let draft: AttachedIssueDraft?
    /// A link to resolve as soon as the sheet opens, skipping the entry step.
    var directReference: String? = nil
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
        directReference: String? = nil,
        onCancel: @escaping () -> Void,
        onAttach: @escaping (AttachedIssueDraft) -> Void
    ) {
        _model = State(initialValue: AttachIssueDialogModel(
            environment: environment,
            initialDraft: initialDraft,
            directReference: directReference
        ))
        _autocomplete = State(initialValue: IssueAutocompleteModel(load: environment.loadSuggestions))
        self.onCancel = onCancel
        self.onAttach = onAttach
    }

    private static let title = "Attach ticket"
    private static let subtitle = "Resolve a ticket and prepare the first Chat prompt."

    var body: some View {
        Group {
            if model.resolvesDirectly, model.phase != .confirmation {
                directResolutionSheet
            } else {
                switch model.phase {
                case .entry, .resolving:
                    entrySheet
                case .confirmation:
                    confirmationSheet
                }
            }
        }
        .task { await model.resolveDirectReference() }
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
            title: Self.title,
            subtitle: Self.subtitle,
            content: {
                DialogField(label: "Ticket link") {
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
                        onFocusLost: {
                            autocomplete.dismiss()
                            autocomplete.cancelInFlightLoad()
                        }
                    )
                }
                if model.phase == .resolving {
                    HStack(spacing: 8) {
                        Spinner(lineWidth: 1.5, duration: 0.7)
                            .frame(width: 14, height: 14)
                        Text("Resolving ticket…")
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
            confirmTitle: model.phase == .resolving ? "Resolving…" : "Resolve ticket",
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

    /// The confirmation layout with placeholders while the link it was opened
    /// on resolves, so the sheet does not change shape when the ticket lands.
    private var directResolutionSheet: some View {
        DialogContainer(
            title: Self.title,
            subtitle: Self.subtitle,
            width: DialogContainerLayout.projectWidth,
            content: {
                ticketCard(heading: "Fetching ticket…", url: model.reference, isLoading: true)
                DialogField(label: "Title") { placeholder(height: 28) }
                DialogField(label: "Ticket context") { placeholder(height: 106) }
                DialogField(label: "Initial prompt") { placeholder(height: 146) }
            },
            cancelTitle: "Cancel",
            confirmTitle: "Attach",
            confirmStyle: .primary,
            onCancel: onCancel,
            onConfirm: {},
            confirmEnabled: false
        )
    }

    private var confirmationSheet: some View {
        DialogContainer(
            title: Self.title,
            subtitle: Self.subtitle,
            width: DialogContainerLayout.projectWidth,
            content: {
                if let source = model.resolved?.source {
                    ticketCard(
                        heading: [source.providerLabel, source.displayReference].compactMap { $0 }.joined(separator: " "),
                        url: source.canonicalURL.absoluteString,
                        isLoading: false
                    )
                }
                DialogField(label: "Title") {
                    AlasField(text: Bindable(model).title)
                }
                DialogField(label: "Ticket context") {
                    textEditor(text: Bindable(model).context, minHeight: 90, maxHeight: 150)
                }
                DialogField(label: "Type") {
                    HStack(spacing: 8) {
                        Picker("", selection: kindBinding) {
                            Text("Generic").tag(IssueKind?.none)
                            ForEach(IssueKind.allCases, id: \.self) { kind in
                                Text(kind.displayName).tag(IssueKind?.some(kind))
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                        if let caption = model.kindCaption {
                            Text(caption)
                                .font(.system(size: 11))
                                .foregroundColor(theme.color("fg-dim"))
                        }
                        Spacer(minLength: 0)
                        if model.canResetPrompt {
                            AlasButton(title: "Reset to template", style: .subtle, action: model.resetPromptToTemplate)
                        }
                    }
                }
                DialogField(label: "Initial prompt") {
                    textEditor(text: promptBinding, minHeight: 130, maxHeight: 190)
                }
            },
            cancelTitle: "Cancel",
            confirmTitle: "Attach",
            confirmStyle: .primary,
            onCancel: onCancel,
            onConfirm: attach,
            confirmEnabled: model.makeDraft() != nil
        )
    }

    /// The ticket being attached. "Change…" returns to the entry step, keeping
    /// the link, so another ticket can be picked without leaving the sheet.
    private func ticketCard(heading: String, url: String, isLoading: Bool) -> some View {
        HStack(spacing: 8) {
            if isLoading {
                Spinner(lineWidth: 1.5, duration: 0.7)
                    .frame(width: 14, height: 14)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(heading)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.color("fg"))
                Text(url)
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("fg-dim"))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            AlasButton(title: "Change…", style: .subtle, action: model.cancelResolution)
        }
        .padding(8)
        .background(theme.color("bg-0"))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(theme.color("line"), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
    }

    private func placeholder(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(theme.color("bg-0"))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(theme.color("line"), lineWidth: 0.5)
            )
            .frame(height: height)
            .accessibilityHidden(true)
    }

    private var kindBinding: Binding<IssueKind?> {
        Binding(
            get: { model.kind },
            set: { model.setKind($0) }
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
