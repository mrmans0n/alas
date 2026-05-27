import Foundation

struct ACPLaunchSpec: Equatable {
    let agentID: String
    let command: String
    let arguments: [String]
    let extraEnv: [String: String]
    let setupCheck: ACPSetupCheck
    let supportsModelSelection: Bool
    let supportsModeSelection: Bool
}
