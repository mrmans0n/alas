import Foundation

/// Pure translation from peer wire frames to the local composer's models,
/// so the peer composer reuses the local chip views and action logic.
enum NativePeerComposerState {
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
            id: id, blocks: [.text(displayText(for: item))],
            scheduledAt: item.scheduledAt.map { Date(timeIntervalSince1970: $0 / 1_000) },
            status: item.status == "sending" ? .sending : .pending,
            lastError: item.lastError)
    }

    /// The wire carries attachments only as counts. Without a marker an
    /// image-only or resource-only item would render as "(empty prompt)".
    static func displayText(for item: RemoteQueuedPrompt) -> String {
        var markers: [String] = []
        if item.imageCount > 0 { markers.append("🖼 ×\(item.imageCount)") }
        if item.resourceCount > 0 { markers.append("📎 ×\(item.resourceCount)") }
        guard !markers.isEmpty else { return item.text }
        let summary = markers.joined(separator: " ")
        return item.text.isEmpty ? summary : item.text + "\n" + summary
    }

    /// The host refuses to edit an item holding images or mentions, so the
    /// row hides Edit for them, as the web queue does.
    static func canEdit(_ item: RemoteQueuedPrompt) -> Bool {
        item.canRemove != false && item.imageCount == 0 && item.resourceCount == 0
    }

    /// Clear only helps when it can remove something: host-protected entries
    /// (`canRemove == false`) survive it.
    static func canClear(_ items: [RemoteQueuedPrompt]) -> Bool {
        items.contains { $0.canRemove != false }
    }

    static func slashSuggestions(from config: RemoteSessionConfig?) -> [ACPPromptSuggestion] {
        (config?.availableCommands ?? []).map {
            ACPPromptSuggestion(command: $0.command, description: $0.description, hint: $0.hint)
        }
    }

    /// Replaces the `/` or `@` token being typed with the pick and a
    /// trailing space, as the local picker does. Offsets are UTF-16, the
    /// unit `ACPSlashCommand.activeToken` and text selections share.
    static func completingToken(
        _ pick: String, in text: String, tokenStart: Int, caret: Int
    ) -> (text: String, caret: Int) {
        let string = text as NSString
        let replacement = pick + " "
        let range = NSRange(location: tokenStart, length: max(0, caret - tokenStart))
        return (string.replacingCharacters(in: range, with: replacement),
                tokenStart + (replacement as NSString).length)
    }

    /// The `@` token the caret is in: an `@` at the start or after
    /// whitespace, then no whitespace up to the caret. Paths and
    /// `File.swift#name` drill-downs are single tokens.
    static func activeMentionToken(in text: NSString, caret: Int) -> (start: Int, query: String)? {
        guard caret <= text.length else { return nil }
        func isSpace(_ unit: unichar) -> Bool {
            unit == 0x20 || unit == 0x0A || unit == 0x09 || unit == 0x0D
        }
        var index = caret
        while index > 0 {
            let unit = text.character(at: index - 1)
            if unit == 0x40 {
                guard index == 1 || isSpace(text.character(at: index - 2)) else { return nil }
                return (index - 1, text.substring(with: NSRange(location: index, length: caret - index)))
            }
            if isSpace(unit) { return nil }
            index -= 1
        }
        return nil
    }

    static func mentionIconName(_ mention: RemoteMention) -> String {
        switch mention.kind {
        case RemoteMention.session: "bubble.left.and.text.bubble.right"
        case RemoteMention.symbol: "curlybraces"
        default: mention.value.hasSuffix("/") ? "folder" : "doc"
        }
    }

    /// The picked mentions whose `@name` is still in `text` as a whole
    /// token. Mentions sharing a name keep one each per marker left, in
    /// pick order.
    static func liveMentions(_ mentions: [RemoteMention], in text: String) -> [RemoteMention] {
        var markersLeft: [String: Int] = [:]
        return mentions.filter { mention in
            let count = markersLeft[mention.name] ?? markerCount(mention.name, in: text as NSString)
            markersLeft[mention.name] = count - 1
            return count > 0
        }
    }

    /// `@name` occurrences that start a token and end it, allowing trailing
    /// punctuation before whitespace or the end: `@App.swift.` keeps
    /// `App.swift`, while `@App` matches neither `@Apple` nor `@App.swift`.
    private static func markerCount(_ name: String, in text: NSString) -> Int {
        let marker = "@" + name
        let punctuation = CharacterSet(charactersIn: ".,;:!?)]}\"'")
        func scalar(at index: Int) -> UnicodeScalar { UnicodeScalar(text.character(at: index)) ?? "a" }
        func endsToken(at start: Int) -> Bool {
            var index = start
            while index < text.length, punctuation.contains(scalar(at: index)) { index += 1 }
            return index == text.length || CharacterSet.whitespacesAndNewlines.contains(scalar(at: index))
        }
        var count = 0
        var search = NSRange(location: 0, length: text.length)
        while true {
            let found = text.range(of: marker, options: [], range: search)
            guard found.location != NSNotFound else { return count }
            let end = NSMaxRange(found)
            let starts = found.location == 0
                || CharacterSet.whitespacesAndNewlines.contains(scalar(at: found.location - 1))
            if starts && endsToken(at: end) { count += 1 }
            search = NSRange(location: end, length: text.length - end)
        }
    }

    struct DictationEdit: Equatable {
        var text: String
        /// The volatile span the next update replaces; nil once committed.
        var span: NSRange?
        var caret: Int
    }

    /// Applies a dictation update the way the local text view does: a
    /// volatile update replaces the previous volatile span in place, a final
    /// one commits it, and with no span open the update replaces the
    /// selection. Ranges are UTF-16.
    static func applyingDictation(
        _ transcript: String, isFinal: Bool, to text: String, span: NSRange?, selection: NSRange
    ) -> DictationEdit {
        let string = text as NSString
        let base = span ?? selection
        let location = min(base.location, string.length)
        let target = NSRange(location: location, length: min(base.length, string.length - location))
        let inserted = NSRange(location: location, length: (transcript as NSString).length)
        return DictationEdit(
            text: string.replacingCharacters(in: target, with: transcript),
            span: isFinal ? nil : inserted,
            caret: NSMaxRange(inserted))
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

    static let attachmentTooLarge = "Attachments can total at most 10 MB."

    /// Why a file of `size` bytes can't join the staged attachments, judged
    /// from sizes alone so it can be checked before the file is read.
    static func attachmentSizeRefusal(_ size: Int, stagedSizes: [Int]) -> String? {
        guard stagedSizes.count < RemoteSessionGateway.maxAttachmentCount else {
            return "A message can carry at most \(RemoteSessionGateway.maxAttachmentCount) images."
        }
        guard stagedSizes.reduce(size, +) <= RemoteSessionGateway.maxAttachmentsBytes else {
            return attachmentTooLarge
        }
        return nil
    }

    /// Why an image can't join the staged attachments, or nil when it can.
    /// Mirrors the host's checks so a send is never refused for them.
    static func attachmentRefusal(_ data: Data, staged: [Data]) -> String? {
        guard ACPImageStaging.sniffMIME(data) != nil else { return "Only PNG, JPEG, GIF and WebP images can be attached." }
        return attachmentSizeRefusal(data.count, stagedSizes: staged.map(\.count))
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
            currentId: chip.currentId)
    }

    private static func presentation(_ value: String) -> ACPParameterChipPresentation {
        switch value {
        case "cursorContextWindow": .cursorContextWindow
        case "fastMode": .fastMode
        default: .standard
        }
    }
}
