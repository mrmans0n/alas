import SwiftUI

struct ACPUserInputPrompt: View {
    @Environment(\.designScale) private var scale
    let request: ACPUserInputRequest
    let onRespond: (UUID, ACPUserInputAction) -> Void
    let onOpenURL: (UUID) async -> Bool
    /// Whether the Skip/Decline and Cancel buttons are offered. A mirrored
    /// peer question has no wire form for either, so it hides them rather
    /// than show buttons that cannot act.
    let showsDismissActions: Bool
    /// Right-hand badge in the header. A question that blocks nothing says so.
    let headerLabel: String
    @Environment(\.theme) private var theme
    @State private var formState: ACPUserInputFormState
    @State private var urlOpenError = false
    @FocusState private var focusedField: String?

    init(
        request: ACPUserInputRequest,
        onRespond: @escaping (UUID, ACPUserInputAction) -> Void,
        onOpenURL: @escaping (UUID) async -> Bool,
        showsDismissActions: Bool = true
    ) {
        self.request = request
        self.onRespond = onRespond
        self.onOpenURL = onOpenURL
        self.showsDismissActions = showsDismissActions
        // An optional question blocks nothing; the agent keeps working.
        self.headerLabel = request.isBlocking ? "Awaiting input" : "Optional"
        _formState = State(initialValue: ACPUserInputFormState(request: request))
    }

    /// Renders a form whose state the caller owns, so something other than
    /// these controls (a visual aid's page clicks) can edit the same selection.
    init(
        formState: ACPUserInputFormState,
        onRespond: @escaping (UUID, ACPUserInputAction) -> Void,
        onOpenURL: @escaping (UUID) async -> Bool,
        showsDismissActions: Bool = true,
        headerLabel: String = "Awaiting input"
    ) {
        self.request = formState.request
        self.onRespond = onRespond
        self.onOpenURL = onOpenURL
        self.showsDismissActions = showsDismissActions
        self.headerLabel = headerLabel
        _formState = State(initialValue: formState)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            switch request.mode {
            case .form:
                formBody
                actionRow
            case .url(let urlRequest):
                urlBody(urlRequest)
                urlActions
            }
        }
        .background(theme.color("bg-1").opacity(0.96))
        .clipShape(.rect(cornerRadius: scale.radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: scale.radius.medium)
                .strokeBorder(theme.color("accent").opacity(0.55), lineWidth: 1)
        )
        .defaultFocus($focusedField, initialFocusKey)
    }

    private var header: some View {
        HStack(spacing: scale.space[2]) {
            Image(systemName: iconName)
                .font(scale.meta.font(weight: .semibold))
                .foregroundStyle(theme.color("accent"))
                .frame(width: 18, height: 18)
            Text(headerTitle)
                .font(scale.meta.font(weight: .semibold))
                .foregroundStyle(theme.color("accent"))
            Spacer(minLength: 8)
            Text(headerLabel)
                .font(scale.caption.font(weight: .semibold))
                .foregroundStyle(theme.color("fg-muted"))
        }
        .padding(.horizontal, scale.space[3])
        .padding(.vertical, scale.space[2])
        .background(theme.color("accent").opacity(0.08))
    }

    private var formBody: some View {
        VStack(alignment: .leading, spacing: scale.space[3]) {
            if shouldShowPromptText {
                promptText
            }
            ForEach(renderedGroups) { group in
                VStack(alignment: .leading, spacing: scale.space[2]) {
                    fieldView(group.field)
                    if let note = group.note {
                        noteView(note)
                    }
                }
            }
        }
        .padding(scale.space[3])
    }

    private var promptText: some View {
        VStack(alignment: .leading, spacing: scale.space[1]) {
            if shouldShowTitle, let title = request.title {
                Text(title)
                    .font(scale.titleFont)
                    .foregroundStyle(theme.color("fg"))
            }
            if Self.shouldShowMessage(for: request) {
                Text(request.message)
                    .font(scale.metaFont)
                    .foregroundStyle(theme.color("fg"))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var shouldShowPromptText: Bool {
        shouldShowTitle || Self.shouldShowMessage(for: request)
    }

    private var shouldShowTitle: Bool {
        request.title != nil && request.title != request.message
    }

    static func shouldShowMessage(for request: ACPUserInputRequest) -> Bool {
        let renderedFields = renderedFields(for: request)
        // Only the first field sits directly under the message; a later
        // field that repeats it is not adjacent, so it is not a duplicate.
        guard let field = renderedFields.first else {
            return true
        }
        let whitespace = CharacterSet.whitespacesAndNewlines
        return request.message.trimmingCharacters(in: whitespace)
            != field.label.trimmingCharacters(in: whitespace)
    }

    static func renderedFields(for request: ACPUserInputRequest) -> [ACPUserInputField] {
        request.fields.filter(isRendered)
    }

    private static func isRendered(_ field: ACPUserInputField) -> Bool {
        field.isSupported || field.required
    }

    private struct RenderedGroup: Identifiable {
        let field: ACPUserInputField
        let note: ACPUserInputField?
        var id: String { field.key }
    }

    /// Each rendered question with its note field, so the note sits directly
    /// under the question it belongs to. A note whose question is not
    /// rendered stays a field of its own rather than disappearing.
    private var renderedGroups: [RenderedGroup] {
        request.fieldGroups.flatMap { group -> [RenderedGroup] in
            let note = group.note.flatMap { Self.isRendered($0) ? $0 : nil }
            if Self.isRendered(group.field) {
                return [RenderedGroup(field: group.field, note: note)]
            }
            return note.map { [RenderedGroup(field: $0, note: nil)] } ?? []
        }
    }

    /// A question's note field, under its question rather than as a field of
    /// its own.
    private func noteView(_ field: ACPUserInputField) -> some View {
        VStack(alignment: .leading, spacing: scale.space[1]) {
            Text(field.noteLabel)
                .font(scale.captionFont)
                .foregroundStyle(theme.color("fg-muted"))
            if let description = field.schema.description, !description.isEmpty {
                Text(description)
                    .font(scale.caption.font(weight: .regular))
                    .foregroundStyle(theme.color("fg-muted"))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            fieldControl(field)
            if formState.shouldShowError(for: field),
               let error = formState.validationError(for: field) {
                Text(error)
                    .font(scale.caption.font(weight: .regular))
                    .foregroundStyle(.red)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(field.noteLabel)
    }

    @ViewBuilder
    private func fieldView(_ field: ACPUserInputField) -> some View {
        VStack(alignment: .leading, spacing: scale.space[2]) {
            HStack(spacing: scale.space[1]) {
                Text(field.label)
                    .font(scale.meta.font(weight: .semibold))
                    .foregroundStyle(theme.color("fg"))
                if field.required {
                    Text("Required")
                        .font(scale.captionFont)
                        .foregroundStyle(theme.color("fg-faint"))
                }
            }
            if let description = field.schema.description, !description.isEmpty {
                Text(description)
                    .font(scale.metaFont)
                    .foregroundStyle(theme.color("fg-muted"))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            fieldControl(field)
            if formState.shouldShowError(for: field),
               let error = formState.validationError(for: field) {
                Text(error)
                    .font(scale.caption.font(weight: .regular))
                    .foregroundStyle(.red)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(field.label)
    }

    @ViewBuilder
    private func fieldControl(_ field: ACPUserInputField) -> some View {
        switch field.schema.type {
        case "string" where !field.schema.options.isEmpty:
            optionList(field)
        case "string" where field.schema.format == "date" || field.schema.format == "date-time":
            dateField(field)
        case "string" where field.schema.isSecret:
            SecureField(field.label, text: textBinding(for: field))
                .textFieldStyle(.plain)
                .font(scale.metaFont)
                .foregroundColor(theme.color("fg"))
                .alasFieldChrome(theme: theme)
                .focused($focusedField, equals: field.key)
        case "string":
            TextField(field.label, text: textBinding(for: field))
                .textFieldStyle(.plain)
                .font(scale.metaFont)
                .foregroundColor(theme.color("fg"))
                .alasFieldChrome(theme: theme)
                .focused($focusedField, equals: field.key)
        case "number", "integer":
            numericField(field)
        case "boolean":
            Toggle(
                field.label,
                isOn: Binding(
                    get: { formState.booleanValues[field.key] ?? false },
                    set: {
                        formState.booleanValues[field.key] = $0
                        formState.markTouched(field.key)
                    }
                )
            )
            .labelsHidden()
        case "array":
            optionList(field)
        default:
            HStack(spacing: scale.space[2]) {
                Image(systemName: "exclamationmark.triangle")
                Text("Unsupported field type: \(field.schema.type)")
            }
            .font(scale.metaFont)
            .foregroundStyle(theme.color("fg-muted"))
        }
    }

    private func optionList(_ field: ACPUserInputField) -> some View {
        VStack(alignment: .leading, spacing: scale.space[2]) {
            ForEach(field.schema.options) { option in
                let selected = formState.selectionValues[field.key]?.contains(option.const) == true
                Button {
                    formState.toggle(option.const, for: field)
                } label: {
                    HStack(alignment: .top, spacing: scale.space[2]) {
                        Image(systemName: selectionIcon(selected: selected, multiple: field.schema.type == "array"))
                            .foregroundStyle(selected ? theme.color("accent") : theme.color("fg-faint"))
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: scale.space[0]) {
                            Text(option.title ?? option.const)
                                .foregroundStyle(theme.color("fg"))
                            if let description = option.description, !description.isEmpty {
                                Text(description)
                                    .font(scale.caption.font(weight: .regular))
                                    .foregroundStyle(theme.color("fg-muted"))
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .font(scale.metaFont)
                    .padding(.horizontal, scale.space[2])
                    .padding(.vertical, scale.space[2])
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(selected ? theme.color("accent").opacity(0.11) : theme.color("bg-0").opacity(0.4))
                    .clipShape(.rect(cornerRadius: scale.radius.medium))
                    .overlay(
                        RoundedRectangle(cornerRadius: scale.radius.medium)
                            .strokeBorder(selected ? theme.color("accent").opacity(0.45) : theme.color("line"), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private func numericField(_ field: ACPUserInputField) -> some View {
        HStack(spacing: scale.space[2]) {
            TextField(field.label, text: textBinding(for: field))
                .textFieldStyle(.plain)
                .font(scale.metaFont)
                .foregroundColor(theme.color("fg"))
                .alasFieldChrome(theme: theme)
                .focused($focusedField, equals: field.key)
            Button {
                step(field, delta: -1)
            } label: {
                Image(systemName: "minus")
            }
            .help("Decrease")
            Button {
                step(field, delta: 1)
            } label: {
                Image(systemName: "plus")
            }
            .help("Increase")
        }
    }

    private func textBinding(for field: ACPUserInputField) -> Binding<String> {
        Binding(
            get: { formState.textValues[field.key] ?? "" },
            set: {
                formState.textValues[field.key] = $0
                formState.markTouched(field.key)
            }
        )
    }

    @ViewBuilder
    private func dateField(_ field: ACPUserInputField) -> some View {
        if formState.dateValues[field.key] != nil {
            DatePicker(
                field.label,
                selection: Binding(
                    get: { formState.dateValues[field.key] ?? Date() },
                    set: {
                        formState.dateValues[field.key] = $0
                        formState.markTouched(field.key)
                    }
                ),
                displayedComponents: field.schema.format == "date" ? [.date] : [.date, .hourAndMinute]
            )
            .labelsHidden()
        } else {
            Button {
                formState.dateValues[field.key] = Date()
                formState.markTouched(field.key)
            } label: {
                Label("Choose Date", systemImage: "calendar")
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: scale.space[2]) {
            if showsDismissActions {
                Button(secondaryActionTitle) { onRespond(request.id, .decline) }
                // Skipping an optional question is all there is to dismiss.
                if request.isBlocking {
                    Button("Cancel", role: .cancel) { onRespond(request.id, .cancel) }
                }
            }
            Spacer()
            Button(primaryActionTitle) {
                if let content = formState.submittedContent() {
                    onRespond(request.id, .submit(content))
                }
            }
            .buttonStyle(.borderedProminent)
            // An optional submit that gives Codex no answer is a Skip.
            .disabled(!request.isBlocking && !formState.hasOptionalAnswer)
        }
        .padding(.horizontal, scale.space[3])
        .padding(.vertical, scale.space[2])
        .background(theme.color("bg-0").opacity(0.45))
    }

    private func urlBody(_ urlRequest: ACPUserInputRequest.URLRequest) -> some View {
        VStack(alignment: .leading, spacing: scale.space[2]) {
            promptText
            HStack(spacing: scale.space[2]) {
                Image(systemName: "globe")
                Text(urlRequest.url.host ?? urlRequest.url.absoluteString)
                    .fontWeight(.semibold)
            }
            .font(scale.metaFont)
            .foregroundStyle(theme.color("fg"))
            Text(urlRequest.url.absoluteString)
                .font(scale.caption.font(weight: .regular, design: .monospaced))
                .foregroundStyle(theme.color("fg-muted"))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let warning = urlWarning(urlRequest.url) {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(scale.caption.font(weight: .regular))
                    .foregroundStyle(.orange)
            }
            if urlOpenError {
                Text("The browser could not open this URL.")
                    .font(scale.caption.font(weight: .regular))
                    .foregroundStyle(.red)
            }
        }
        .padding(scale.space[3])
    }

    private var urlActions: some View {
        HStack(spacing: scale.space[2]) {
            Button("Decline") { onRespond(request.id, .decline) }
            Button("Cancel", role: .cancel) { onRespond(request.id, .cancel) }
            Spacer()
            Button("Open Browser") {
                Task { @MainActor in
                    urlOpenError = !(await onOpenURL(request.id))
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, scale.space[3])
        .padding(.vertical, scale.space[2])
        .background(theme.color("bg-0").opacity(0.45))
    }

    /// An optional question must not take focus from the composer.
    private var initialFocusKey: String? {
        guard request.isBlocking else { return nil }
        return request.fields.first {
            $0.schema.type == "string" && $0.schema.options.isEmpty
        }?.key
    }

    private var headerTitle: String {
        if case .url = request.mode { return "Continue in browser" }
        return request.isBlocking ? "Input requested" : "Codex asks"
    }

    private var iconName: String {
        if case .url = request.mode { return "rectangle.portrait.and.arrow.right" }
        return "questionmark.bubble"
    }

    private var primaryActionTitle: String {
        if case .cursor = request.source { return "Answer" }
        return "Submit"
    }

    private var secondaryActionTitle: String {
        if case .cursor = request.source { return "Skip" }
        return request.isBlocking ? "Decline" : "Skip"
    }

    private func selectionIcon(selected: Bool, multiple: Bool) -> String {
        if multiple { return selected ? "checkmark.square.fill" : "square" }
        return selected ? "largecircle.fill.circle" : "circle"
    }

    private func step(_ field: ACPUserInputField, delta: Double) {
        let current = Double(formState.textValues[field.key] ?? "") ?? 0
        var next = current + delta
        if let minimum = field.schema.minimum { next = max(next, minimum) }
        if let maximum = field.schema.maximum { next = min(next, maximum) }
        formState.textValues[field.key] = field.schema.type == "integer"
            ? String(Int(next))
            : String(next)
        formState.markTouched(field.key)
    }

    private func urlWarning(_ url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""
        if host.contains("xn--") { return "This address contains an encoded international domain." }
        if url.scheme?.lowercased() == "http", host != "localhost", host != "127.0.0.1" {
            return "This address does not use HTTPS."
        }
        return nil
    }
}

struct ACPPlanApprovalSection: Equatable {
    let title: String?
    let items: [ACPMessage.PlanItem]
}

struct ACPPlanApprovalPrompt: View {
    @Environment(\.designScale) private var scale
    let plan: ACPCursorCreatePlanParams
    let onRespond: (ACPCursorPlanResponse) -> Void
    @Environment(\.theme) private var theme
    @State private var rejectionReason = ""
    @FocusState private var isRejectionReasonFocused: Bool

    /// Top-level todos first (untitled), then one titled section per phase
    /// that has todos, so a phased plan is reviewed in full before approval.
    static func checklistSections(for plan: ACPCursorCreatePlanParams) -> [ACPPlanApprovalSection] {
        var sections: [ACPPlanApprovalSection] = []
        if !plan.todos.isEmpty {
            sections.append(.init(title: nil, items: plan.todos.map(Self.item)))
        }
        for phase in plan.phases where !phase.todos.isEmpty {
            sections.append(.init(title: phase.name, items: phase.todos.map(Self.item)))
        }
        return sections
    }

    private static func item(_ todo: ACPCursorTodo) -> ACPMessage.PlanItem {
        .init(content: todo.content, status: todo.status)
    }

    private var trimmedRejectionReason: String {
        rejectionReason.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: scale.space[3]) {
                if !plan.overview.isEmpty {
                    Text(plan.overview)
                        .font(scale.metaFont)
                        .foregroundStyle(theme.color("fg"))
                }
                ACPMarkdownText(raw: plan.plan, typography: .default)
                ForEach(Array(Self.checklistSections(for: plan).enumerated()), id: \.offset) { _, section in
                    VStack(alignment: .leading, spacing: scale.space[1]) {
                        if let title = section.title {
                            Text(title)
                                .font(scale.meta.font(weight: .semibold))
                                .foregroundStyle(theme.color("fg-muted"))
                        }
                        ACPPlanChecklist(items: section.items)
                            .clipShape(.rect(cornerRadius: scale.radius.medium))
                    }
                }
            }
            .padding(scale.space[3])
            VStack(alignment: .leading, spacing: scale.space[2]) {
                TextField("Reason for rejection", text: $rejectionReason)
                    .textFieldStyle(.plain)
                    .font(scale.metaFont)
                    .foregroundColor(theme.color("fg"))
                    .alasFieldChrome(theme: theme)
                    .focused($isRejectionReasonFocused)
                HStack(spacing: scale.space[2]) {
                    Button("Reject") {
                        onRespond(.init(outcome: .rejected(reason: trimmedRejectionReason)))
                    }
                    .disabled(trimmedRejectionReason.isEmpty)
                    Spacer()
                    Button("Accept") {
                        onRespond(.init(outcome: .accepted(planUri: "alas://plans/\(plan.toolCallId)")))
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(scale.space[3])
            .background(theme.color("bg-0").opacity(0.45))
        }
        .background(theme.color("bg-1").opacity(0.96))
        .clipShape(.rect(cornerRadius: scale.radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: scale.radius.medium)
                .strokeBorder(theme.color("accent").opacity(0.55), lineWidth: 1)
        )
        .defaultFocus($isRejectionReasonFocused, false)
    }

    private var header: some View {
        HStack(spacing: scale.space[2]) {
            Image(systemName: "checklist")
                .font(scale.meta.font(weight: .semibold))
                .foregroundStyle(theme.color("accent"))
                .frame(width: 18, height: 18)
            Text(plan.name)
                .font(scale.meta.font(weight: .semibold))
                .foregroundStyle(theme.color("accent"))
            Spacer(minLength: 8)
            Text("Plan approval")
                .font(scale.caption.font(weight: .semibold))
                .foregroundStyle(theme.color("fg-muted"))
        }
        .padding(.horizontal, scale.space[3])
        .padding(.vertical, scale.space[2])
        .background(theme.color("accent").opacity(0.08))
    }
}

struct ACPURLElicitationWaitView: View {
    @Environment(\.designScale) private var scale
    let wait: ACPURLElicitationWait
    let onOpenAgain: (URL) -> Void
    let onDismiss: (String) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: scale.space[2]) {
            Spinner(lineWidth: 1.5)
                .frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: scale.space[0]) {
                Text("Waiting for browser completion")
                    .font(scale.meta.font(weight: .semibold))
                    .foregroundStyle(theme.color("fg"))
                Text(wait.url.host ?? wait.url.absoluteString)
                    .font(scale.caption.font(weight: .regular))
                    .foregroundStyle(theme.color("fg-muted"))
            }
            Spacer()
            Button("Open Again") { onOpenAgain(wait.url) }
            Button("Dismiss") { onDismiss(wait.id) }
        }
        .padding(scale.space[2])
        .background(theme.color("bg-1").opacity(0.9))
        .clipShape(.rect(cornerRadius: scale.radius.medium))
        .overlay(RoundedRectangle(cornerRadius: scale.radius.medium).strokeBorder(theme.color("line"), lineWidth: 0.5))
    }
}
