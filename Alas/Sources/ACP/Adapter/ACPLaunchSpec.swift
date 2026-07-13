import Foundation

struct ACPLaunchSpec: Equatable {
    let agentID: String
    let command: String
    let arguments: [String]
    let extraEnv: [String: String]
    let setupCheck: ACPSetupCheck
    let supportsModelSelection: Bool
    let supportsModeSelection: Bool
    let remoteNodeBinDirectory: String?

    init(
        agentID: String,
        command: String,
        arguments: [String],
        extraEnv: [String: String],
        setupCheck: ACPSetupCheck,
        supportsModelSelection: Bool,
        supportsModeSelection: Bool,
        remoteNodeBinDirectory: String? = nil
    ) {
        self.agentID = agentID
        self.command = command
        self.arguments = arguments
        self.extraEnv = extraEnv
        self.setupCheck = setupCheck
        self.supportsModelSelection = supportsModelSelection
        self.supportsModeSelection = supportsModeSelection
        self.remoteNodeBinDirectory = remoteNodeBinDirectory
    }

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

    /// A copy of this spec with `command` replaced and all other fields
    /// unchanged. Used to launch a resolved absolute path through the
    /// launcher's existing absolute-path branch.
    func overridingCommand(
        _ command: String,
        remoteNodeBinDirectory: String? = nil
    ) -> ACPLaunchSpec {
        ACPLaunchSpec(
            agentID: agentID,
            command: command,
            arguments: arguments,
            extraEnv: extraEnv,
            setupCheck: setupCheck,
            supportsModelSelection: supportsModelSelection,
            supportsModeSelection: supportsModeSelection,
            remoteNodeBinDirectory: remoteNodeBinDirectory)
    }
}
