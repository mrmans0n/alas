struct GGEffectiveConfig: Equatable, Sendable {
    var syncAutoRebase: Bool
    var syncBehindThreshold: Int

    static let defaults = GGEffectiveConfig(syncAutoRebase: false, syncBehindThreshold: 1)
}

struct GGCapabilities: Equatable, Sendable {
    var structuredSplit: Bool
    var keepCurrentUnstack: Bool
    var clientOperationID: Bool = false
    var stagedOnlyAmend: Bool = false
}
