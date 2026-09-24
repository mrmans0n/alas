import SwiftUI

/// Read and drive the selected peer through forwarded gateway frames only.
struct NativePeerSessionView: View {
    @Bindable var client: NativePeerSessions
    @State private var questionSelections: [String: Set<String>] = [:]
    @State private var elicitationValues: [String: String] = [:]

    private var online: Bool { client.selectedPeer?.state.carriesSessions == true }
    private var canDrive: Bool { online && client.transcript?.canDrive == true }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let transcript = client.transcript {
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
                    }
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                    .padding(20)
                }
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
        let kind = message.kind
        let title: String = switch kind {
        case "user": "You"
        case "agent": "Agent"
        case "thought": "Thought"
        case "toolCall": "Tool call"
        case "fileEdit": "File edit"
        case "plan": "Plan"
        case "systemNotice": "System"
        default: "Message"
        }
        return VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let text = message.text, !text.isEmpty {
                Text(text).textSelection(.enabled)
            } else {
                Text("Structured \(title.lowercased())")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(kind == "user" ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func pendingRequests(_ transcript: NativePeerTranscript) -> some View {
        if let request = transcript.pendingPermission {
            VStack(alignment: .leading, spacing: 8) {
                Text(request.title ?? "Allow \(request.toolName)?").font(.headline)
                if let reason = request.reason { Text(reason).font(.callout) }
                HStack {
                    ForEach(request.options, id: \.optionId) { option in
                        Button(option.name) {
                            client.decidePermission(requestId: request.requestId, optionId: option.optionId)
                        }
                        .disabled(!canDrive)
                    }
                }
            }
            .requestCard()
        }
        if let request = transcript.pendingQuestion {
            VStack(alignment: .leading, spacing: 8) {
                Text(request.title ?? "Question").font(.headline)
                ForEach(request.questions, id: \.id) { question in
                    Text(question.prompt)
                    HStack {
                        ForEach(question.options, id: \.id) { option in
                            Button {
                                var selected = questionSelections[question.id] ?? []
                                if selected.contains(option.id) { selected.remove(option.id) }
                                else if question.allowMultiple { selected.insert(option.id) }
                                else { selected = [option.id] }
                                questionSelections[question.id] = selected
                            } label: {
                                Label(option.label, systemImage: questionSelections[question.id]?.contains(option.id) == true
                                      ? "checkmark.circle.fill" : "circle")
                            }
                            .disabled(!canDrive)
                        }
                    }
                }
                Button("Submit answers") {
                    client.answerQuestion(requestId: request.requestId, answers: request.questions.map {
                        RemoteQuestionAnswer(questionId: $0.id,
                                             selectedOptionIds: Array(questionSelections[$0.id] ?? []).sorted())
                    })
                }
                .disabled(!canDrive || request.questions.contains { (questionSelections[$0.id] ?? []).isEmpty })
            }
            .requestCard()
        }
        if let request = transcript.pendingPlan {
            VStack(alignment: .leading, spacing: 8) {
                Text(request.name).font(.headline)
                Text(request.overview).font(.callout)
                HStack {
                    Button("Accept plan") { client.respondToPlan(requestId: request.requestId, action: "accept") }
                    Button("Reject plan") { client.respondToPlan(requestId: request.requestId, action: "reject") }
                }
                .disabled(!canDrive)
            }
            .requestCard()
        }
        if let request = transcript.pendingElicitation {
            VStack(alignment: .leading, spacing: 8) {
                Text(request.title ?? "Information requested").font(.headline)
                Text(request.message).font(.callout)
                ForEach(request.fields, id: \.key) { field in
                    TextField(field.title, text: Binding(
                        get: { elicitationValues[field.key] ?? "" },
                        set: { elicitationValues[field.key] = $0 }
                    ))
                    .disabled(!canDrive)
                }
                HStack {
                    Button("Submit") {
                        let content = Dictionary(uniqueKeysWithValues: request.fields.compactMap { field -> (String, ACPElicitationValue)? in
                            guard let value = elicitationValues[field.key], !value.isEmpty else { return nil }
                            switch field.type {
                            case "integer": return Int(value).map { (field.key, .integer($0)) }
                            case "number": return Double(value).map { (field.key, .number($0)) }
                            case "boolean": return (field.key, .boolean(value == "true"))
                            default: return (field.key, .string(value))
                            }
                        })
                        client.respondToElicitation(requestId: request.requestId, action: "accept", content: content)
                    }
                    .disabled(!canDrive || request.fields.contains { $0.required && (elicitationValues[$0.key] ?? "").isEmpty })
                    Button("Decline") {
                        client.respondToElicitation(requestId: request.requestId, action: "decline")
                    }
                    .disabled(!canDrive)
                }
            }
            .requestCard()
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
                if transcript.streamingState == "streaming" {
                    Button("Stop") { client.stopSelected() }
                        .disabled(!canDrive)
                }
                Button("Send") { client.sendPrompt() }
                    .disabled(!canDrive || client.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(14)
    }
}

private extension View {
    func requestCard() -> some View {
        self.frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}
