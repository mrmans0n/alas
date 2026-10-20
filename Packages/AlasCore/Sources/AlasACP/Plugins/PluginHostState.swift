import Foundation
import Observation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

public enum PluginHostState: Equatable, Sendable {
    case loaded
    case activating
    case active
    case deactivating
    case stopped
    case failed(String)
}

public struct PluginTraceEntry: Equatable, Sendable {
    public enum Direction: Sendable {
        case toPlugin
        case fromPlugin
    }

    public let direction: Direction
    public let text: String

    public init(direction: Direction, text: String) {
        self.direction = direction
        self.text = text
    }
}

public struct PluginLogEntry: Equatable, Sendable {
    public let level: String
    public let message: String

    public init(level: String, message: String) {
        self.level = level
        self.message = message
    }
}

public struct PluginTaskRequest: Equatable, Sendable {
    public let title: String
    public let prompt: String
    public let branch: String?
    public let agent: String?

    public init(title: String, prompt: String, branch: String?, agent: String?) {
        self.title = title
        self.prompt = prompt
        self.branch = branch
        self.agent = agent
    }
}

/// What `prompt/expand` gave: the prompt text, or why there is none, ready to show the user.
public enum PluginPromptExpansion: Equatable, Sendable {
    case text(String)
    case failed(String)
    /// Another expansion for the same session is still waiting; a repeated send is ignored.
    case busy
}

public enum PluginTaskStart: Equatable, Sendable {
    case started(sessionId: String, branch: String)
    case rejected(code: Int, message: String)
}

public enum PluginWorktreeLocation: Equatable, Sendable {
    case local(URL)
    /// `root` is the worktree's real path on `host`.
    case remote(host: String, root: String)
}
