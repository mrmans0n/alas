import SwiftUI

struct ACPUserInputPrompt: View {
    let request: ACPUserInputRequest
    let onRespond: (UUID, ACPUserInputAction) -> Void
    let onOpenURL: (UUID) async -> Bool
    @Environment(\.theme) private var theme
    @State private var formState: ACPUserInputFormState
    @State private var urlOpenError = false
    @FocusState private var focusedField: String?

    init(
        request: ACPUserInputRequest,
        onRespond: @escaping (UUID, ACPUserInputAction) -> Void,
        onOpenURL: @escaping (UUID) async -> Bool
    ) {
        self.request = request
        self.onRespond = onRespond
        self.onOpenURL = onOpenURL
        _formState = State(initialValue: ACPUserInputFormState(request: request))
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
        .clipShape(.rect(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(theme.color("accent").opacity(0.55), lineWidth: 1)
        )
        .defaultFocus($focusedField, initialFocusKey)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.color("accent"))
                .frame(width: 18, height: 18)
            Text(headerTitle)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.color("accent"))
            Spacer(minLength: 8)
            Text("Awaiting input")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(theme.color("fg-muted"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(theme.color("accent").opacity(0.08))
    }

    private var formBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            promptText
            ForEach(request.fields.filter { $0.isSupported || $0.required }) { field in
                fieldView(field)
            }
        }
        .padding(12)
    }

    private var promptText: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title = request.title, title != request.message {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.color("fg"))
            }
            Text(request.message)
                .font(.system(size: 12.5))
                .foregroundStyle(theme.color("fg"))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func fieldView(_ field: ACPUserInputField) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(field.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.color("fg"))
                if field.required {
                    Text("Required")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(theme.color("fg-faint"))
                }
            }
            if let description = field.schema.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.color("fg-muted"))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            fieldControl(field)
            if formState.shouldShowError(for: field),
               let error = formState.validationError(for: field) {
                Text(error)
                    .font(.system(size: 10.5))
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
        case "string":
            TextField(
                field.label,
                text: Binding(
                    get: { formState.textValues[field.key] ?? "" },
                    set: {
                        formState.textValues[field.key] = $0
                        formState.markTouched(field.key)
                    }
                )
            )
            .textFieldStyle(.roundedBorder)
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
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                Text("Unsupported field type: \(field.schema.type)")
            }
            .font(.system(size: 11))
            .foregroundStyle(theme.color("fg-muted"))
        }
    }

    private func optionList(_ field: ACPUserInputField) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(field.schema.options) { option in
                let selected = formState.selectionValues[field.key]?.contains(option.const) == true
                Button {
                    formState.toggle(option.const, for: field)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: selectionIcon(selected: selected, multiple: field.schema.type == "array"))
                            .foregroundStyle(selected ? theme.color("accent") : theme.color("fg-faint"))
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.title ?? option.const)
                                .foregroundStyle(theme.color("fg"))
                            if let description = option.description, !description.isEmpty {
                                Text(description)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(theme.color("fg-muted"))
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 11.5))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(selected ? theme.color("accent").opacity(0.11) : theme.color("bg-0").opacity(0.4))
                    .clipShape(.rect(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(selected ? theme.color("accent").opacity(0.45) : theme.color("line"), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private func numericField(_ field: ACPUserInputField) -> some View {
        HStack(spacing: 6) {
            TextField(
                field.label,
                text: Binding(
                    get: { formState.textValues[field.key] ?? "" },
                    set: {
                        formState.textValues[field.key] = $0
                        formState.markTouched(field.key)
                    }
                )
            )
            .textFieldStyle(.roundedBorder)
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
        HStack(spacing: 8) {
            Button(secondaryActionTitle) { onRespond(request.id, .decline) }
            Button("Cancel", role: .cancel) { onRespond(request.id, .cancel) }
            Spacer()
            Button(primaryActionTitle) {
                if let content = formState.submittedContent() {
                    onRespond(request.id, .submit(content))
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(theme.color("bg-0").opacity(0.45))
    }

    private func urlBody(_ urlRequest: ACPUserInputRequest.URLRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            promptText
            HStack(spacing: 6) {
                Image(systemName: "globe")
                Text(urlRequest.url.host ?? urlRequest.url.absoluteString)
                    .fontWeight(.semibold)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(theme.color("fg"))
            Text(urlRequest.url.absoluteString)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(theme.color("fg-muted"))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let warning = urlWarning(urlRequest.url) {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
            }
            if urlOpenError {
                Text("The browser could not open this URL.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
    }

    private var urlActions: some View {
        HStack(spacing: 8) {
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
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(theme.color("bg-0").opacity(0.45))
    }

    private var initialFocusKey: String? {
        request.fields.first {
            $0.schema.type == "string" && $0.schema.options.isEmpty
        }?.key
    }

    private var headerTitle: String {
        if case .url = request.mode { return "Continue in browser" }
        return "Input requested"
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
        return "Decline"
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

struct ACPURLElicitationWaitView: View {
    let wait: ACPURLElicitationWait
    let onOpenAgain: (URL) -> Void
    let onDismiss: (String) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 9) {
            Spinner(lineWidth: 1.5)
                .frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text("Waiting for browser completion")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(theme.color("fg"))
                Text(wait.url.host ?? wait.url.absoluteString)
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.color("fg-muted"))
            }
            Spacer()
            Button("Open Again") { onOpenAgain(wait.url) }
            Button("Dismiss") { onDismiss(wait.id) }
        }
        .padding(10)
        .background(theme.color("bg-1").opacity(0.9))
        .clipShape(.rect(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(theme.color("line"), lineWidth: 0.5))
    }
}
