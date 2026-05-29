import Foundation

struct ACPLaunchSpec: Equatable {
    let agentID: String
    let command: String
    let arguments: [String]
    let extraEnv: [String: String]
    let setupCheck: ACPSetupCheck
    let supportsModelSelection: Bool
    let supportsModeSelection: Bool

    /// The npm package that installs/updates this adapter, when the setup
    /// check exposes one. Binary-only adapters (gemini, opencode,
    /// cursor-agent, copilot) return nil — Alas does not own their install.
    var npmPackageName: String? {
        switch setupCheck {
        case .binaryOnPath: return nil
        case .npxPackage(let name): return name
        case .binaryOnPathOrNpmPackage(_, let npmPackage): return npmPackage
        }
    }
}
