import Foundation

/// Session instructions: text the user sets per agent, captured when Alas
/// creates a session and sent as `_meta.systemPrompt.append` on that session's
/// session/new, session/load, session/resume, and session/fork. It never goes
/// into the transcript as a user message.
///
/// - Claude (`claude-agent-acp`): appended to the Claude Code preset; user and
///   project CLAUDE.md files still load. Upstream reads the field on every
///   lifecycle method for any client, without an initialize advertisement.
///   Verified against 0.91.0-alas.1 with a request-capturing provider: the
///   text reached the system prompt exactly once on new, load in the same
///   process, load after a restart, and fork.
/// - Codex (`codex-acp`): joined after the configured `developer_instructions`
///   instead of replacing them (upstream PR #585, carried in our fork). Only
///   adapters that advertise `_meta.systemPrompt.append` on initialize get it.
///   Codex cannot change the instructions of a thread its process already has
///   loaded; the fork accepts a repeat of the same text there and rejects a
///   different one, so a session must always send what it was created with.
///
/// Neither path needs the AIR client declaration.
public enum ACPSessionInstructionsPolicy {
    /// Whether the agent editor offers the setting for `agentID`.
    public static func isConfigurable(agentID: String) -> Bool {
        agentID == ACPManagedAdapterDescriptor.claude.agentID
            || agentID == ACPManagedAdapterDescriptor.codex.agentID
    }

    /// The stored form of user-entered text: nil when it is blank.
    public static func normalized(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    /// The append to send for a session of `agentID` whose captured
    /// instructions are `captured`, or nil to send none.
    public static func append(agentID: String, captured: String?, advertisesAppend: Bool) -> String? {
        guard let captured = normalized(captured) else { return nil }
        switch agentID {
        case ACPManagedAdapterDescriptor.claude.agentID:
            return captured
        case ACPManagedAdapterDescriptor.codex.agentID:
            return advertisesAppend ? captured : nil
        default:
            return nil
        }
    }
}
