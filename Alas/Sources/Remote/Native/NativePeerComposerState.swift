import Foundation

/// Pure translation from peer wire frames to the local composer's models,
/// so the peer composer reuses the local chip views and action logic.
enum NativePeerComposerState {
    @MainActor
    struct EditorContext {
        let client: NativePeerSessions
        let sessionId: String

        var config: RemoteSessionConfig? {
            client.selectedSessionId == sessionId ? client.transcript?.config : nil
        }

        var isOpen: Bool {
            client.selectedSessionId == sessionId
                && client.selectedPeer?.state.carriesSessions == true
                && client.transcript?.epoch != nil
                && client.transcript?.isClosed == false
        }
    }

    private struct PeerMention: Codable {
        let peerId: String
        let mention: RemoteMention
    }

    /// Remote resources must retain their host identity when copied as chips.
    /// A local file URI or a chip from another peer cannot name a host resource.
    static func mentionURI(_ mention: RemoteMention, peerId: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(PeerMention(peerId: peerId, mention: mention)) else { return "" }
        return "alas-peer-mention:" + data.base64EncodedString()
    }

    static func mention(from uri: String, peerId: String) -> RemoteMention? {
        let prefix = "alas-peer-mention:"
        guard uri.hasPrefix(prefix),
              let data = Data(base64Encoded: String(uri.dropFirst(prefix.count))),
              let resource = try? JSONDecoder().decode(PeerMention.self, from: data),
              resource.peerId == peerId else { return nil }
        return resource.mention
    }

    static func chipState(from config: RemoteSessionConfig) -> ACPChipState {
        guard let chips = config.chips else {
            return ACPChipState(
                models: config.models.isEmpty ? nil : ChipSpec(
                    source: .model,
                    options: config.models.map { .init(id: $0.id, name: $0.name, description: nil) },
                    currentId: config.currentModel),
                mode: config.modes.isEmpty ? nil : ChipSpec(
                    source: .mode,
                    options: config.modes.map { .init(id: $0.id, name: $0.name, description: nil) },
                    currentId: config.currentMode),
                thinking: nil, parameters: [], autoRun: .supported)
        }
        return ACPChipState(
            models: chips.model.flatMap(spec),
            mode: chips.mode.flatMap(spec),
            thinking: chips.thinking.flatMap(spec),
            parameters: chips.parameters.compactMap { parameter in
                spec(parameter.chip).map {
                    ACPParameterChip(id: parameter.id, label: parameter.label,
                                     presentation: presentation(parameter.presentation), spec: $0)
                }
            },
            autoRun: chips.autoRun == "ignored" ? .ignored : .supported)
    }

    static func configOptions(from config: RemoteSessionConfig) -> [ACPConfigOption] {
        (config.chips?.booleans ?? []).map {
            ACPConfigOption(id: $0.id, name: $0.name, type: "boolean", category: nil,
                            currentValue: ACPConfigValue.boolean($0.value), options: [])
        }
    }

    static func streamingState(_ wire: String) -> ACPSession.StreamingState {
        switch wire {
        case "sending": .sending
        case "streaming": .streaming
        case "awaitingPermission": .awaitingPermission
        case "awaitingInput": .awaitingInput
        default: .idle
        }
    }

    static func queuedPrompt(_ item: RemoteQueuedPrompt) -> QueuedPrompt? {
        guard let id = UUID(uuidString: item.id) else { return nil }
        return QueuedPrompt(
            id: id, blocks: [.text(RemoteQueueRules.displayText(for: item))],
            scheduledAt: item.scheduledAt.map { Date(timeIntervalSince1970: $0 / 1_000) },
            status: item.status == "sending" ? .sending : .pending,
            lastError: item.lastError)
    }

    static func slashSuggestions(from config: RemoteSessionConfig?) -> [ACPPromptSuggestion] {
        (config?.availableCommands ?? []).map {
            ACPPromptSuggestion(command: $0.command, description: $0.description, hint: $0.hint)
        }
    }

    static func mentionIconName(_ mention: RemoteMention) -> String {
        switch mention.kind {
        case RemoteMention.session: "bubble.left.and.text.bubble.right"
        case RemoteMention.symbol: "curlybraces"
        default: mention.value.hasSuffix("/") ? "folder" : "doc"
        }
    }

    /// The local context ring's inputs, rebuilt from the host's reduced
    /// rows. Each row becomes a "model" whose total is the row's tokens,
    /// which is all the popover reads.
    static func contextUsage(from usage: RemoteUsage)
        -> (usage: ACPUsageInfo?, lastTurn: ACPPromptQuota?, cumulative: ACPPromptQuota?)
    {
        func quota(_ rows: [RemoteTokenUsage]) -> ACPPromptQuota? {
            guard !rows.isEmpty else { return nil }
            return ACPPromptQuota(tokenCount: nil, modelUsage: rows.map {
                ACPModelUsage(model: $0.label, tokenCount: ACPTokenCount(
                    totalTokens: $0.tokens, inputTokens: 0, cachedInputTokens: 0,
                    cachedWriteTokens: 0, outputTokens: 0, reasoningOutputTokens: 0))
            })
        }
        let context = usage.context.map { window in
            ACPUsageInfo(used: window.used, size: window.size, cost: window.costAmount.flatMap { amount in
                window.costCurrency.map { ACPUsageInfo.Cost(amount: amount, currency: $0) }
            })
        }
        return (context, quota(usage.lastTurn), quota(usage.cumulative))
    }

    struct MoveTargets: Equatable {
        var up: String?
        var down: String?
    }

    /// The queue item each row's Move up / Move down would swap with, by the
    /// local row's rules. The host re-checks against its full queue.
    static func moveTargets(_ items: [RemoteQueuedPrompt]) -> [String: MoveTargets] {
        let queue = items.compactMap(queuedPrompt)
        func target(from index: Int, step: Int) -> String? {
            guard let neighbour = ACPTranscriptQueuePolicy.adjacentRenderedIndex(from: index, step: step, queue: queue),
                  ACPTranscriptQueuePolicy.canMoveQueueItem(from: index, to: neighbour, queue: queue)
            else { return nil }
            return queue[neighbour].id.uuidString
        }
        var targets: [String: MoveTargets] = [:]
        for index in queue.indices where ACPTranscriptQueuePolicy.shouldRenderQueueBubble(queue[index]) {
            targets[queue[index].id.uuidString] = MoveTargets(up: target(from: index, step: -1),
                                                              down: target(from: index, step: 1))
        }
        return targets
    }

    static let tooManyMentions = "A message can mention at most \(RemoteAttachmentLimits.maxMentionCount) items."

    /// Why an image can't join the staged attachments, or nil when it can.
    /// Mirrors the host's checks so a send is never refused for them.
    static func attachmentRefusal(_ data: Data, staged: [Data]) -> String? {
        guard ACPImageStaging.sniffMIME(data) != nil else { return "Only PNG, JPEG, GIF and WebP images can be attached." }
        return RemoteAttachmentLimits.refusal(adding: data.count, to: staged.map(\.count))
    }

    private static func spec(_ chip: RemoteChip) -> ChipSpec? {
        let source: ChipSpec.Source
        switch chip.source {
        case "model": source = .model
        case "mode": source = .mode
        case "config":
            guard let id = chip.configId else { return nil }
            source = .configOption(id: id)
        default: return nil
        }
        return ChipSpec(
            source: source,
            options: chip.options.map {
                .init(id: $0.id, name: $0.name, description: $0.description,
                      kind: $0.kind.flatMap(ACPModeKind.init(rawValue:)))
            },
            currentId: chip.currentId,
            recommendedId: chip.recommendedId)
    }

    private static func presentation(_ value: String) -> ACPParameterChipPresentation {
        switch value {
        case "cursorContextWindow": .cursorContextWindow
        case "fastMode": .fastMode
        default: .standard
        }
    }
}
