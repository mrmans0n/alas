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
            id: id, blocks: [.text(item.text)],
            scheduledAt: item.scheduledAt.map { Date(timeIntervalSince1970: $0 / 1_000) },
            status: item.status == "sending" ? .sending : .pending,
            lastError: item.lastError)
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
