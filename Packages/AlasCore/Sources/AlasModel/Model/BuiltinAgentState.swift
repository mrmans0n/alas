import Foundation
import AlasFoundation

/// Persisted per-built-in agent state. Built-in static knowledge
/// (display name, args, flags, logo) lives in `AgentBuiltins.catalog`;
/// only what the user can change is stored on disk.
public struct BuiltinAgentState: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var binaryOverride: String?
    public var extraTerminalArgs: [String]?
    /// "Disable native subagents" for new ACP sessions of this agent.
    /// Absent (nil) means off. Only honoured where
    /// `ACPNativeDelegationSupport` has a verified control.
    public var nativeSubagentsDisabled: Bool?
    /// "Session instructions" for new ACP sessions of this agent. Absent
    /// (nil) means none. See `ACPSessionInstructionsPolicy`.
    public var sessionInstructions: String?

    public init(
        isEnabled: Bool,
        binaryOverride: String? = nil,
        extraTerminalArgs: [String]? = nil,
        nativeSubagentsDisabled: Bool? = nil,
        sessionInstructions: String? = nil
    ) {
        self.isEnabled = isEnabled
        self.binaryOverride = binaryOverride
        self.extraTerminalArgs = extraTerminalArgs
        self.nativeSubagentsDisabled = nativeSubagentsDisabled
        self.sessionInstructions = sessionInstructions
    }
}
