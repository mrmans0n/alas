import Foundation

enum AgentLifecycleEventMapper {
    static func map(_ rawEvent: String) -> ActivityEvent? {
        if let event = ActivityEvent(rawValue: rawEvent) {
            return event
        }

        switch rawEvent {
        case "SessionStart", "sessionStart", "session_start":
            return .attached
        case "SessionEnd", "sessionEnd", "session_end":
            return .detached
        case "UserPromptSubmit",
             "PostToolUse",
             "PostToolUseFailure",
             "BeforeAgent",
             "AfterTool",
             "userPromptSubmitted",
             "postToolUse",
             "task_started":
            return .busy
        case "PermissionRequest",
             "PreToolUse",
             "preToolUse",
             "exec_approval_request",
             "apply_patch_approval_request",
             "request_user_input":
            return .permissionRequest
        case "Stop",
             "stop",
             "AfterAgent",
             "task_complete",
             "agent-turn-complete":
            return .idle
        default:
            return nil
        }
    }
}
