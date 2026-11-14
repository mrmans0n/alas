import AlasACP
import AlasFoundation
import Foundation

/// The currently selected peer transcript; the state machine lives in `AlasRemoteKit`.
typealias NativePeerTranscript = RemoteTranscriptState<HostServerMessage, HostClientMessage>

extension RemoteTranscriptState {
    /// Reflects a chip change locally until the host's next `sessionConfig`
    /// frame overwrites it.
    mutating func applyOptimistic(_ spec: ChipSpec, itemId: String) {
        updateConfig { config in
            switch spec.source {
            case .model:
                config.currentModel = itemId
                config.chips?.model?.currentId = itemId
            case .mode:
                config.currentMode = itemId
                config.chips?.mode?.currentId = itemId
            case .configOption(let id):
                if config.chips?.model?.configId == id { config.chips?.model?.currentId = itemId }
                if config.chips?.thinking?.configId == id { config.chips?.thinking?.currentId = itemId }
                if config.chips?.mode?.configId == id { config.chips?.mode?.currentId = itemId }
                if let chips = config.chips {
                    for index in chips.parameters.indices where chips.parameters[index].chip.configId == id {
                        config.chips?.parameters[index].chip.currentId = itemId
                    }
                }
            }
        }
    }
}
