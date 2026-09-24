import SwiftUI

struct NativePeerMessagePresentation {
    let title: String
    let body: String

    init(message: RemoteWireMessage) {
        let data = message.json.map { Data($0.utf8) }
        switch message.kind {
        case "user":
            title = "You"
            body = message.text ?? ""
        case "agent":
            title = "Agent"
            body = message.text ?? ""
        case "thought":
            title = "Thought"
            body = message.text ?? ""
        case "systemNotice":
            title = "System"
            body = message.text ?? ""
        case "toolCall":
            if let data, let call = try? JSONDecoder().decode(ACPMessage.ToolCall.self, from: data) {
                title = "Tool call · \(call.title)"
                body = Self.limited([call.status, call.content.isEmpty ? call.preview : call.content]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n"))
            } else {
                title = "Tool call"
                body = "Tool details are unavailable."
            }
        case "fileEdit":
            if let data, let edit = try? JSONDecoder().decode(ACPMessage.FileEdit.self, from: data) {
                title = "File edit"
                body = Self.limited("\(edit.path) · +\(edit.added) −\(edit.removed)\n\n\(edit.newText)")
            } else {
                title = "File edit"
                body = "Edit details are unavailable."
            }
        case "plan":
            if let data, let items = try? JSONDecoder().decode([ACPMessage.PlanItem].self, from: data) {
                title = "Plan"
                body = Self.limited(items.map { "\($0.status): \($0.content)" }.joined(separator: "\n"))
            } else {
                title = "Plan"
                body = "Plan details are unavailable."
            }
        default:
            title = "Message"
            body = message.text ?? ""
        }
    }

    private static func limited(_ text: String) -> String {
        String(text.prefix(4_000))
    }
}

struct NativePeerPermissionPresentation {
    let title: String
    let toolName: String
    let mcpServerName: String?
    let commandSummary: String?
    let defaultToNo: Bool

    init(request: RemotePermissionPayload) {
        title = request.title ?? "Permission request"
        toolName = request.toolName
        mcpServerName = request.mcpServerName
        commandSummary = request.commandSummary.flatMap {
            $0.isEmpty || $0 == request.toolName ? nil : $0
        }
        defaultToNo = request.defaultToNo
    }

    func isDefaultStyled(_ option: RemotePermissionOption) -> Bool {
        defaultToNo ? option.kind == "reject_once" : option.kind == "allow_once"
    }

    func isDefaultAction(_ option: RemotePermissionOption) -> Bool {
        defaultToNo && isDefaultStyled(option)
    }

    func description(for option: RemotePermissionOption) -> String? {
        guard let description = option.description, !description.isEmpty else { return nil }
        return description
    }
}

/// Read and drive the selected peer through forwarded gateway frames only.
struct NativePeerSessionView: View {
    @Bindable var client: NativePeerSessions
    @State private var followsTranscriptTail = true

    private var online: Bool { client.selectedPeer?.state.carriesSessions == true }
    private var canDrive: Bool { online && client.transcript?.canDrive == true }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let transcript = client.transcript {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if !online || transcript.isClosed {
                                unavailableBanner
                            }
                            if transcript.olderPageBeforeIndex != nil && online {
                                Button("Load older messages") { client.fetchOlder() }
                                    .buttonStyle(.borderless)
                            }
                            ForEach(transcript.messages, id: \.stableId) { message in
                                messageCard(message)
                            }
                            pendingRequests(transcript)
                            Color.clear
                                .frame(height: 1)
                                .id(NativePeerTranscriptScrollPolicy.tailAnchorID)
                        }
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity)
                        .padding(20)
                    }
                    .onAppear {
                        proxy.scrollTo(NativePeerTranscriptScrollPolicy.tailAnchorID, anchor: .bottom)
                    }
                    .onChange(of: transcript) { _, _ in
                        guard followsTranscriptTail else { return }
                        proxy.scrollTo(NativePeerTranscriptScrollPolicy.tailAnchorID, anchor: .bottom)
                    }
                    .onScrollGeometryChange(for: Bool.self) { geometry in
                        let distanceFromBottom = geometry.contentSize.height - geometry.contentOffset.y
                            - geometry.containerSize.height
                        return NativePeerTranscriptScrollPolicy.shouldFollow(
                            distanceFromBottom: distanceFromBottom
                        )
                    } action: { _, shouldFollow in
                        followsTranscriptTail = shouldFollow
                    }
                }
                .id(client.selectedSessionId ?? "peer-transcript")
                Divider()
                composer(transcript)
            } else {
                ContentUnavailableView("No peer session selected", systemImage: "desktopcomputer")
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "desktopcomputer")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(client.selectedRow?.title ?? "Peer session")
                    .font(.headline)
                Text([client.selectedPeer?.name, client.selectedRow?.worktree?.projectName,
                      client.selectedRow?.worktree?.worktreeName,
                      client.selectedRow?.worktree?.branch]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Close") { client.clearSelection() }
        }
        .padding(16)
    }

    private var unavailableBanner: some View {
        HStack {
            Image(systemName: "wifi.slash")
            Text("This peer session is unavailable. Your draft is preserved until you close it.")
            Spacer()
            Button("Return") { client.clearSelection() }
        }
        .font(.callout)
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func messageCard(_ message: RemoteWireMessage) -> some View {
        let presentation = NativePeerMessagePresentation(message: message)
        return VStack(alignment: .leading, spacing: 5) {
            Text(presentation.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(presentation.body).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(message.kind == "user" ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func pendingRequests(_ transcript: NativePeerTranscript) -> some View {
        if let request = transcript.pendingPermission {
            VStack(alignment: .leading, spacing: 8) {
                let presentation = NativePeerPermissionPresentation(request: request)
                Text(presentation.title).font(.headline)
                Text(presentation.toolName)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                if let commandSummary = presentation.commandSummary {
                    Text(commandSummary)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
                if let server = presentation.mcpServerName, !server.isEmpty {
                    Text("via \(server)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let reason = request.reason { Text(reason).font(.callout) }
                permissionOptions(request, presentation: presentation)
            }
            .requestCard()
        }
        if let request = transcript.pendingQuestion {
            NativePeerQuestionRequestCard(request: request, canDrive: canDrive, client: client)
                .id("\(client.selectedSessionId ?? ""):\(request.requestId)")
        }
        if let request = transcript.pendingPlan {
            NativePeerPlanRequestCard(request: request, canDrive: canDrive, client: client)
                .id("\(client.selectedSessionId ?? ""):\(request.requestId)")
        }
        if let request = transcript.pendingElicitation {
            NativePeerElicitationRequestCard(request: request, canDrive: canDrive, client: client)
                .id("\(client.selectedSessionId ?? ""):\(request.requestId)")
        }
    }

    @ViewBuilder
    private func permissionOptions(
        _ request: RemotePermissionPayload,
        presentation: NativePeerPermissionPresentation
    ) -> some View {
        if request.options.contains(where: { presentation.description(for: $0) != nil }) {
            VStack(alignment: .trailing, spacing: 8) {
                ForEach(request.options, id: \.optionId) { option in
                    VStack(alignment: .trailing, spacing: 3) {
                        HStack {
                            Spacer()
                            permissionButton(option, presentation: presentation, request: request)
                        }
                        if let description = presentation.description(for: option) {
                            Text(description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
            }
        } else {
            HStack {
                ForEach(request.options, id: \.optionId) { option in
                    permissionButton(option, presentation: presentation, request: request)
                }
            }
        }
    }

    @ViewBuilder
    private func permissionButton(
        _ option: RemotePermissionOption,
        presentation: NativePeerPermissionPresentation,
        request: RemotePermissionPayload
    ) -> some View {
        if presentation.isDefaultStyled(option) {
            Button(option.name) {
                client.decidePermission(requestId: request.requestId, optionId: option.optionId)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(presentation.isDefaultAction(option) ? .defaultAction : nil)
            .disabled(!canDrive)
        } else {
            Button(option.name) {
                client.decidePermission(requestId: request.requestId, optionId: option.optionId)
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(presentation.isDefaultAction(option) ? .defaultAction : nil)
            .disabled(!canDrive)
        }
    }

    private func composer(_ transcript: NativePeerTranscript) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = client.deliveryError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            TextEditor(text: $client.draft)
                .font(.body)
                .frame(minHeight: 55, maxHeight: 110)
                .disabled(!canDrive)
                .accessibilityLabel("Message peer session")
            HStack {
                if online, transcript.epoch != nil, !transcript.isClosed, !transcript.canDrive {
                    Button("Take over") { client.takeOver() }
                }
                Spacer()
                if NativePeerSessionControls.showsStop(for: transcript.streamingState) {
                    Button("Stop") { client.stopSelected() }
                        .disabled(!online || transcript.isClosed)
                }
                Button("Send") { client.sendPrompt() }
                    .disabled(!canDrive || client.isPromptPending
                        || client.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(14)
    }
}

enum NativePeerPlanPresentation {
    static func details(for request: RemotePlanPayload) -> String {
        var sections: [String] = []
        if !request.plan.isEmpty {
            sections.append(request.plan)
        }
        if !request.todos.isEmpty {
            sections.append(([
                "Todos:",
            ] + request.todos.map(todoLine)).joined(separator: "\n"))
        }
        for phase in request.phases {
            sections.append((["Phase: \(phase.name)"] + phase.todos.map(todoLine)).joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    private static func todoLine(_ todo: RemotePlanTodo) -> String {
        "- [\(todo.status)] \(todo.content)"
    }
}

enum NativePeerSessionControls {
    static func showsStop(for streamingState: String) -> Bool {
        streamingState != "idle"
    }
}

enum NativePeerTranscriptScrollPolicy {
    static let tailAnchorID = "native-peer-transcript-tail"
    private static let bottomTolerance: CGFloat = 72

    static func shouldFollow(distanceFromBottom: CGFloat) -> Bool {
        distanceFromBottom <= bottomTolerance
    }
}

struct NativePeerQuestionSelectionState: Equatable {
    private(set) var requestId: Int
    var selectedOptions: [String: Set<String>] = [:]

    init(requestId: Int) {
        self.requestId = requestId
    }

    mutating func reset(requestId: Int) {
        self = Self(requestId: requestId)
    }

    mutating func toggle(_ optionId: String, for question: RemoteQuestion) {
        var selected = selectedOptions[question.id] ?? []
        if selected.contains(optionId) {
            selected.remove(optionId)
        } else if question.allowMultiple {
            selected.insert(optionId)
        } else {
            selected = [optionId]
        }
        selectedOptions[question.id] = selected
    }
}

struct NativePeerPlanRejectionState: Equatable {
    private(set) var requestId: JSONRPCID
    var reason = ""

    init(requestId: JSONRPCID) {
        self.requestId = requestId
    }

    mutating func reset(requestId: JSONRPCID) {
        self = Self(requestId: requestId)
    }
}

enum NativePeerElicitationForm {
    struct State: Equatable {
        private(set) var requestId: String
        var values: [String: String] = [:]
        var selectedOptions: [String: Set<String>] = [:]
        var booleanValues: [String: Bool] = [:]

        init(requestId: String, fields: [RemoteElicitationField]) {
            self.requestId = requestId
            seed(fields)
        }

        mutating func reset(requestId: String, fields: [RemoteElicitationField]) {
            guard self.requestId != requestId else { return }
            self = Self(requestId: requestId, fields: fields)
        }

        private mutating func seed(_ fields: [RemoteElicitationField]) {
            for field in fields {
                guard let defaultValue = field.defaultValue else {
                    if field.type == "boolean", field.required { booleanValues[field.key] = false }
                    continue
                }
                switch (field.type, defaultValue) {
                case ("string", .string(let value)) where field.options.isEmpty:
                    values[field.key] = value
                case ("string", .string(let value)) where field.options.contains(where: { $0.value == value }):
                    selectedOptions[field.key] = [value]
                case ("integer", .integer(let value)):
                    values[field.key] = String(value)
                case ("number", .integer(let value)):
                    values[field.key] = String(value)
                case ("number", .number(let value)):
                    values[field.key] = String(value)
                case ("boolean", .boolean(let value)):
                    booleanValues[field.key] = value
                case ("array", .strings(let values)):
                    let allowed = Set(field.options.map(\.value))
                    selectedOptions[field.key] = Set(values.filter(allowed.contains))
                default:
                    break
                }
            }
        }
    }

    static func canSubmit(
        fields: [RemoteElicitationField],
        values: [String: String],
        selectedOptions: [String: Set<String>],
        booleanValues: [String: Bool] = [:]
    ) -> Bool {
        fields.allSatisfy {
            validationMessage(for: $0, values: values, selectedOptions: selectedOptions,
                              booleanValues: booleanValues) == nil
        }
    }

    static func validationMessage(
        for field: RemoteElicitationField,
        values: [String: String],
        selectedOptions: [String: Set<String>],
        booleanValues: [String: Bool] = [:]
    ) -> String? {
        switch field.type {
        case "string" where !field.options.isEmpty:
            let selected = selectedOptions[field.key] ?? []
            if selected.isEmpty { return field.required ? "Choose an option." : nil }
            guard selected.count == 1 else { return "Choose one option." }
            guard selected.isSubset(of: Set(field.options.map(\.value))),
                  let value = field.options.first(where: { selected.contains($0.value) })?.value
            else { return "Choose a listed option." }
            return stringValidationMessage(value, for: field)
        case "string":
            let value = values[field.key] ?? ""
            if value.isEmpty { return field.required ? "This field is required." : nil }
            return stringValidationMessage(value, for: field)
        case "integer", "number":
            let rawValue = values[field.key] ?? ""
            if rawValue.isEmpty { return field.required ? "This field is required." : nil }
            guard let value = Double(rawValue), value.isFinite else { return "Enter a valid number." }
            if field.type == "integer", Int(exactly: value) == nil { return "Enter a whole number." }
            if let minimum = field.minimum, value < minimum { return "Enter \(minimum) or greater." }
            if let maximum = field.maximum, value > maximum { return "Enter \(maximum) or less." }
            return nil
        case "boolean":
            return booleanValues[field.key] == nil && field.required ? "Choose true or false." : nil
        case "array":
            let selected = selectedOptions[field.key] ?? []
            let allowed = Set(field.options.map(\.value))
            guard selected.isSubset(of: allowed) else { return "Choose only listed options." }
            if selected.isEmpty && !field.required { return nil }
            let minimum = max(field.required ? 1 : 0, field.minItems ?? 0)
            if selected.count < minimum { return "Choose at least \(minimum) options." }
            if let maximum = field.maxItems, selected.count > maximum {
                return "Choose no more than \(maximum) options."
            }
            return nil
        default:
            return field.required ? "This required field type is not supported." : nil
        }
    }

    private static func stringValidationMessage(_ value: String, for field: RemoteElicitationField) -> String? {
        if let minimum = field.minLength, value.count < minimum {
            return "Enter at least \(minimum) characters."
        }
        if let maximum = field.maxLength, value.count > maximum {
            return "Enter no more than \(maximum) characters."
        }
        if let pattern = field.pattern,
           let regex = try? NSRegularExpression(pattern: pattern),
           regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) == nil {
            return "The value does not match the requested format."
        }
        switch field.format {
        case "email":
            let parts = value.split(separator: "@", omittingEmptySubsequences: false)
            return parts.count == 2 && parts[1].contains(".") ? nil : "Enter a valid email address."
        case "uri":
            return URL(string: value)?.scheme == nil ? "Enter a valid URI." : nil
        case "date":
            return Self.isValidDate(value) ? nil : "Enter a valid date (YYYY-MM-DD)."
        case "date-time":
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let standard = ISO8601DateFormatter()
            return fractional.date(from: value) != nil || standard.date(from: value) != nil
                ? nil : "Enter a valid date and time."
        default:
            return nil
        }
    }

    private static func isValidDate(_ value: String) -> Bool {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }

    static func submittedContent(
        fields: [RemoteElicitationField],
        values: [String: String],
        selectedOptions: [String: Set<String>],
        booleanValues: [String: Bool] = [:]
    ) -> [String: ACPElicitationValue] {
        var content: [String: ACPElicitationValue] = [:]
        for field in fields {
            if field.type == "array" {
                let selected = selectedOptions[field.key] ?? []
                let ordered = field.options.map(\.value).filter(selected.contains)
                if !ordered.isEmpty || field.required {
                    content[field.key] = .strings(ordered)
                }
                continue
            }
            switch field.type {
            case "string" where !field.options.isEmpty:
                if let value = field.options.first(where: {
                    selectedOptions[field.key]?.contains($0.value) == true
                })?.value {
                    content[field.key] = .string(value)
                }
            case "string":
                if let value = values[field.key], !value.isEmpty {
                    content[field.key] = .string(value)
                }
            case "integer":
                if let parsed = Double(values[field.key] ?? ""), let integer = Int(exactly: parsed) {
                    content[field.key] = .integer(integer)
                }
            case "number":
                if let number = Double(values[field.key] ?? ""), number.isFinite {
                    content[field.key] = .number(number)
                }
            case "boolean":
                if let value = booleanValues[field.key] {
                    content[field.key] = .boolean(value)
                } else if field.required {
                    content[field.key] = .boolean(false)
                }
            default:
                continue
            }
        }
        return content
    }
}

struct NativePeerElicitationOptionPresentation {
    let title: String
    let description: String?

    init(option: RemoteElicitationOption) {
        title = option.title ?? option.value
        description = option.description.flatMap { $0.isEmpty ? nil : $0 }
    }
}

enum NativePeerElicitationFieldPresentation {
    static func usesSecureInput(for field: RemoteElicitationField) -> Bool {
        field.type == "string" && field.options.isEmpty && field.isSecret
    }
}

private struct NativePeerQuestionRequestCard: View {
    let request: RemoteQuestionPayload
    let canDrive: Bool
    let client: NativePeerSessions
    @State private var state: NativePeerQuestionSelectionState

    init(request: RemoteQuestionPayload, canDrive: Bool, client: NativePeerSessions) {
        self.request = request
        self.canDrive = canDrive
        self.client = client
        _state = State(initialValue: NativePeerQuestionSelectionState(requestId: request.requestId))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(request.title ?? "Question").font(.headline)
            ForEach(request.questions, id: \.id) { question in
                Text(question.prompt)
                HStack {
                    ForEach(question.options, id: \.id) { option in
                        Button {
                            state.toggle(option.id, for: question)
                        } label: {
                            Label(option.label, systemImage: state.selectedOptions[question.id]?.contains(option.id) == true
                                  ? "checkmark.circle.fill" : "circle")
                        }
                        .disabled(!canDrive)
                    }
                }
            }
            Button("Submit answers") {
                client.answerQuestion(requestId: request.requestId, answers: request.questions.map {
                    RemoteQuestionAnswer(questionId: $0.id,
                                         selectedOptionIds: Array(state.selectedOptions[$0.id] ?? []).sorted())
                })
            }
        .disabled(!canDrive || request.questions.contains { (state.selectedOptions[$0.id] ?? []).isEmpty })
        }
        .requestCard()
        .onChange(of: request) { _, request in state.reset(requestId: request.requestId) }
    }
}

private struct NativePeerPlanRequestCard: View {
    let request: RemotePlanPayload
    let canDrive: Bool
    let client: NativePeerSessions
    @State private var state: NativePeerPlanRejectionState

    private var trimmedReason: String {
        state.reason.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(request: RemotePlanPayload, canDrive: Bool, client: NativePeerSessions) {
        self.request = request
        self.canDrive = canDrive
        self.client = client
        _state = State(initialValue: NativePeerPlanRejectionState(requestId: request.requestId))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(request.name).font(.headline)
            if !request.overview.isEmpty { Text(request.overview).font(.callout) }
            let details = NativePeerPlanPresentation.details(for: request)
            if !details.isEmpty {
                Text(details)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("Reason for rejection", text: $state.reason)
                .disabled(!canDrive)
            HStack {
                Button("Accept plan") { client.respondToPlan(requestId: request.requestId, action: "accept") }
                Button("Reject plan") {
                    client.respondToPlan(requestId: request.requestId, action: "reject", reason: trimmedReason)
                }
                .disabled(!canDrive || trimmedReason.isEmpty)
            }
            .disabled(!canDrive)
        }
        .requestCard()
        .onChange(of: request) { _, request in state.reset(requestId: request.requestId) }
    }
}

private struct NativePeerElicitationRequestCard: View {
    let request: RemoteElicitationPayload
    let canDrive: Bool
    let client: NativePeerSessions
    @Environment(\.openURL) private var openURL
    @State private var formState: NativePeerElicitationForm.State
    @State private var elicitationOpenError = false

    init(request: RemoteElicitationPayload, canDrive: Bool, client: NativePeerSessions) {
        self.request = request
        self.canDrive = canDrive
        self.client = client
        _formState = State(initialValue: NativePeerElicitationForm.State(
            requestId: request.requestId, fields: request.fields
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(request.mode == "url" ? "Continue in browser" : request.title ?? "Information requested")
                .font(.headline)
            Text(request.message).font(.callout)
            if request.mode == "url" {
                urlBody
            } else {
                formBody
            }
        }
        .requestCard()
        .onChange(of: request.requestId) { _, requestId in
            formState.reset(requestId: requestId, fields: request.fields)
            elicitationOpenError = false
        }
    }

    private var urlBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(request.url ?? "URL unavailable.")
                .font(.caption.monospaced())
                .textSelection(.enabled)
            if elicitationOpenError {
                Text("The browser could not open this URL.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Button("Decline") {
                    client.respondToElicitation(requestId: request.requestId, action: "decline")
                }
                .disabled(!canDrive)
                Button("Cancel", role: .cancel) {
                    client.respondToElicitation(requestId: request.requestId, action: "cancel")
                }
                .disabled(!canDrive)
                Spacer()
                Button("Open Browser") {
                    elicitationOpenError = false
                    client.openElicitationURL(requestId: request.requestId, openURL: { url, finish in
                        openURL(url) { accepted in
                            Task { @MainActor in finish(accepted) }
                        }
                    }, completion: { didOpen in
                        elicitationOpenError = !didOpen
                    })
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canDrive)
            }
        }
    }

    private var formBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(request.fields, id: \.key) { field in
                fieldInput(field)
            }
            HStack {
                Button("Submit") {
                    let content = NativePeerElicitationForm.submittedContent(
                        fields: request.fields,
                        values: formState.values,
                        selectedOptions: formState.selectedOptions,
                        booleanValues: formState.booleanValues
                    )
                    client.respondToElicitation(requestId: request.requestId, action: "accept", content: content)
                }
                .disabled(!canDrive || !NativePeerElicitationForm.canSubmit(
                    fields: request.fields,
                    values: formState.values,
                    selectedOptions: formState.selectedOptions,
                    booleanValues: formState.booleanValues
                ))
                Button("Decline") {
                    client.respondToElicitation(requestId: request.requestId, action: "decline")
                }
                .disabled(!canDrive)
                Button("Cancel", role: .cancel) {
                    client.respondToElicitation(requestId: request.requestId, action: "cancel")
                }
                .disabled(!canDrive)
            }
        }
    }

    @ViewBuilder
    private func fieldInput(_ field: RemoteElicitationField) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(field.title).font(.callout.weight(.medium))
                if field.required { Text("Required").font(.caption).foregroundStyle(.secondary) }
            }
            if let description = field.description, !description.isEmpty {
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
            switch field.type {
            case "array":
                ForEach(field.options, id: \.value) { option in
                    let presentation = NativePeerElicitationOptionPresentation(option: option)
                    let selected = formState.selectedOptions[field.key]?.contains(option.value) == true
                    Toggle(isOn: Binding(
                        get: { formState.selectedOptions[field.key]?.contains(option.value) == true },
                        set: { isSelected in
                            var options = formState.selectedOptions[field.key] ?? []
                            if isSelected { options.insert(option.value) }
                            else { options.remove(option.value) }
                            formState.selectedOptions[field.key] = options
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(presentation.title)
                            if let description = presentation.description {
                                Text(description).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(!canDrive || (!selected && field.maxItems.map {
                        (formState.selectedOptions[field.key]?.count ?? 0) >= $0
                    } == true))
                }
            case "string" where !field.options.isEmpty:
                ForEach(field.options, id: \.value) { option in
                    let presentation = NativePeerElicitationOptionPresentation(option: option)
                    let selected = formState.selectedOptions[field.key]?.contains(option.value) == true
                    VStack(alignment: .leading, spacing: 3) {
                        Button {
                            var options = formState.selectedOptions[field.key] ?? []
                            if selected { options.remove(option.value) }
                            else { options = [option.value] }
                            formState.selectedOptions[field.key] = options
                        } label: {
                            Label(presentation.title,
                                  systemImage: selected ? "largecircle.fill.circle" : "circle")
                        }
                        .buttonStyle(.plain)
                        .disabled(!canDrive)
                        if let description = presentation.description {
                            Text(description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 22)
                        }
                    }
                }
            case "string" where NativePeerElicitationFieldPresentation.usesSecureInput(for: field):
                SecureField(field.title, text: Binding(
                    get: { formState.values[field.key] ?? "" },
                    set: { formState.values[field.key] = $0 }
                ))
                .disabled(!canDrive)
            case "boolean":
                Toggle(field.title, isOn: Binding(
                    get: { formState.booleanValues[field.key] ?? false },
                    set: { formState.booleanValues[field.key] = $0 }
                ))
                .disabled(!canDrive)
            case "string", "number", "integer":
                TextField(field.title, text: Binding(
                    get: { formState.values[field.key] ?? "" },
                    set: { formState.values[field.key] = $0 }
                ))
                .disabled(!canDrive)
            default:
                Text("Unsupported field type: \(field.type)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let issue = NativePeerElicitationForm.validationMessage(
                for: field,
                values: formState.values,
                selectedOptions: formState.selectedOptions,
                booleanValues: formState.booleanValues
            ) {
                Text(issue).font(.caption).foregroundStyle(.red)
            }
        }
    }
}

private extension View {
    func requestCard() -> some View {
        self.frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}
