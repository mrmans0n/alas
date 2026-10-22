import CoreFoundation
import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

/// Session hooks: a Claude Code `hooks` object the user sets for the Claude
/// agent, captured when Alas creates a session and sent as
/// `_meta.claudeCode.options.settings.hooks` on that session's session/new,
/// session/load, session/resume, and session/fork.
///
/// - The adapter passes the object to Claude Code as the programmatic settings
///   tier. Claude Code merges hooks across tiers, so user, project, and local
///   hooks still run alongside these. Since claude-agent-acp 0.90.0 (upstream
///   PR #1265, fe8b69e) the adapter merges the object over
///   `CLAUDE_MODEL_CONFIG`; older adapters replace the model configuration
///   with it, so they never get it.
/// - Claude Code runs the hooks itself, on the host and in the environment of
///   the agent process (the remote host for SSH sessions), with the session
///   worktree as the working directory. Alas never installs them in a settings
///   file and never runs them.
/// - The adapter rebuilds a live session only when its settings change, so a
///   session must send the same object on every request: the captured value
///   is written once and re-sent byte for byte. Verified against
///   @alas-ide/claude-agent-acp 0.94.0-alas.1: hooks ran once per event on
///   new, on load after an adapter restart, and alongside user-tier hooks.
public enum ACPClaudeSessionHooksPolicy {
    /// First adapter release that merges session settings with
    /// `CLAUDE_MODEL_CONFIG` instead of replacing it.
    public static let minimumAdapterVersion = "0.90.0"

    /// `HOOK_EVENTS` of the Claude Agent SDK bundled with
    /// @alas-ide/claude-agent-acp 0.94.0-alas.1. Claude Code ignores unknown
    /// events, so a misspelled one would never run.
    public static let events = [
        "PreToolUse", "PostToolUse", "PostToolUseFailure", "PostToolBatch", "Notification",
        "UserPromptSubmit", "UserPromptExpansion", "SessionStart", "SessionEnd", "Stop",
        "StopFailure", "SubagentStart", "SubagentStop", "PreCompact", "PostCompact",
        "PreModelSwitch", "PostModelSwitch", "PermissionRequest", "PermissionDenied", "Setup",
        "TeammateIdle", "TaskCreated", "TaskCompleted", "Elicitation", "ElicitationResult",
        "ConfigChange", "WorktreeCreate", "WorktreeRemove", "InstructionsLoaded", "CwdChanged",
        "FileChanged", "DirectoryAdded", "MessageDisplay",
    ]

    /// Each hook type and the string fields it requires.
    static let requiredFields: [String: [String]] = [
        "command": ["command"],
        "prompt": ["prompt"],
        "agent": ["prompt"],
        "http": ["url"],
        "mcp_tool": ["server", "tool"],
    ]

    /// Whether the agent editor offers the setting for `agentID`.
    public static func isConfigurable(agentID: String) -> Bool {
        agentID == ACPManagedAdapterDescriptor.claude.agentID
    }

    /// The stored form of user-entered JSON: compact with sorted keys, or nil
    /// when it is blank or has no events. Accepts the bare hooks object or a
    /// settings object whose only key is `hooks`.
    public static func normalized(_ text: String?) throws(ACPClaudeSessionHooksError) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else { return nil }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: .fragmentsAllowed)
        } catch {
            throw .invalid("This is not valid JSON.")
        }
        guard var root = parsed as? [String: Any] else {
            throw .invalid(#"Enter an object keyed by event name, like {"PostToolUse": [...]}."#)
        }
        if root.count == 1, let inner = root["hooks"] as? [String: Any] {
            root = inner
        }
        guard !root.isEmpty else { return nil }
        for event in root.keys.sorted() {
            guard events.contains(event) else {
                throw .invalid("\"\(event)\" is not a Claude Code hook event. Use one of: "
                    + events.joined(separator: ", ") + ".")
            }
            try validateMatchers(root[event] as Any, path: event)
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])
        else { throw .invalid("This is not valid JSON.") }
        return String(decoding: data, as: UTF8.self)
    }

    /// The hooks to send for a session of `agentID` that captured `captured`,
    /// or nil to send none. Throws when the session has hooks the adapter
    /// cannot be trusted to apply: running without them would silently drop
    /// guards the user configured.
    public static func sessionHooks(
        agentID: String,
        captured: String?,
        agentInfo: ACPImplementationInfo?
    ) throws(ACPClaudeSessionHooksError) -> LSPJSONValue? {
        guard isConfigurable(agentID: agentID), let stored = try normalized(captured) else { return nil }
        let verified = ACPManagedAdapterDescriptor.claude.verifiedPackageNames
        guard let name = agentInfo?.name, verified.contains(name) else {
            throw .adapterUnverified(found: agentInfo?.name, expected: verified.joined(separator: ", "))
        }
        guard let version = agentInfo?.version,
              ACPNativeDelegationControls.isVersion(version, atLeast: minimumAdapterVersion)
        else {
            throw .adapterVersionUnverified(found: agentInfo?.version, minimum: minimumAdapterVersion)
        }
        guard let value = try? LSPJSONValue.decode(from: Data(stored.utf8)) else {
            throw .invalid("This is not valid JSON.")
        }
        return value
    }

    private static func validateMatchers(_ value: Any, path: String) throws(ACPClaudeSessionHooksError) {
        guard let groups = value as? [Any] else {
            throw .invalid(#"\#(path) must be a list of matcher groups, like [{"matcher": "Bash", "hooks": [...]}]."#)
        }
        for (index, group) in groups.enumerated() {
            let groupPath = "\(path)[\(index)]"
            guard let group = group as? [String: Any] else {
                throw .invalid(#"\#(groupPath) must be an object with a "hooks" list."#)
            }
            if let matcher = group["matcher"], !(matcher is String) {
                throw .invalid("\(groupPath).matcher must be a string.")
            }
            guard let hooks = group["hooks"] as? [Any], !hooks.isEmpty else {
                throw .invalid(#"\#(groupPath) needs a non-empty "hooks" list."#)
            }
            for (hookIndex, hook) in hooks.enumerated() {
                try validateHook(hook, path: "\(groupPath).hooks[\(hookIndex)]")
            }
        }
    }

    private static func validateHook(_ value: Any, path: String) throws(ACPClaudeSessionHooksError) {
        guard let hook = value as? [String: Any] else {
            throw .invalid("\(path) must be an object.")
        }
        let types = requiredFields.keys.sorted()
        guard let type = hook["type"] as? String, let required = requiredFields[type] else {
            throw .invalid("\(path).type must be one of: \(types.joined(separator: ", ")).")
        }
        for field in required {
            guard let text = hook[field] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw .invalid("\(path).\(field) must be a non-empty string for a \(type) hook.") }
        }
        if let timeout = hook["timeout"] {
            guard let seconds = timeout as? NSNumber, !isBool(timeout), seconds.doubleValue > 0 else {
                throw .invalid("\(path).timeout must be a positive number of seconds.")
            }
        }
        if let args = hook["args"], !(args is [String]) {
            throw .invalid("\(path).args must be a list of strings.")
        }
    }

    private static func isBool(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}

public enum ACPClaudeSessionHooksError: LocalizedError, Equatable, Sendable {
    case invalid(String)
    case adapterUnverified(found: String?, expected: String)
    case adapterVersionUnverified(found: String?, minimum: String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let detail):
            // The editor shows this as typed; a session whose captured hooks
            // fail it can only be replaced, not fixed.
            return "Session hooks: \(detail) Fix Session hooks in Settings → Agents; "
                + "a session that already started with them needs a new session."
        case .adapterUnverified(let found, let expected):
            let name = found.map { "\"\($0)\"" } ?? "an unnamed adapter"
            return "This session was started with Claude session hooks, but the "
                + "claude ACP server identified itself as \(name); session hooks are "
                + "verified only for \(expected). Point Alas at that adapter, or start "
                + "a new session after clearing Session hooks in Settings → Agents."
        case .adapterVersionUnverified(let found, let minimum):
            let version = found.map { "version \($0)" } ?? "an unidentified version"
            return "This session was started with Claude session hooks, but the "
                + "claude ACP adapter reported \(version); session hooks need \(minimum) "
                + "or later. Update the adapter, or start a new session after clearing "
                + "Session hooks in Settings → Agents."
        }
    }
}
