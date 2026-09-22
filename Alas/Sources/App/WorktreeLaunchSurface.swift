import Foundation

/// A chat session to open on a new worktree, decided before the worktree
/// exists so a retry reuses the same ids instead of queueing twice.
struct PreparedWorktreeACPPrompt: Equatable, Sendable {
    let sessionID: ACPSession.ID
    let promptID: UUID
    let text: String
    /// Queued to go out as soon as the agent is ready, or left in the
    /// composer for the user to send. Meaningless when `text` is empty.
    var sendsAutomatically = true
    /// Model to switch the session to before the prompt goes out, or nil for
    /// the agent's default.
    var modelID: String? = nil
}

/// Describes what (if anything) the New Worktree dialog should open in the
/// center pane after the worktree is created. Makes invalid combinations
/// (ACP without an agent, "no tab" with an agent) unrepresentable.
enum WorktreeLaunchSurface: Equatable {
    /// No tab is opened. The new worktree is still selected.
    case none
    /// A terminal tab is opened. When `agentId` is non-nil, the agent's
    /// startup command is appended to the session's startup script.
    case terminal(agentId: String?)
    /// An ACP chat session tab is opened for `agentId`. The agent must be
    /// ACP-capable (present in `ACPLaunchCatalog.specs`).
    case acp(agentId: String, preparedPrompt: PreparedWorktreeACPPrompt? = nil)
    /// An API-created worktree. It must not alter selection or open a tab.
    case delegated
}
