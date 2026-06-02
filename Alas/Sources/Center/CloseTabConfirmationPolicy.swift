import Foundation

enum CloseTabConfirmationPolicy {
    enum Prompt: Equatable {
        case terminal
        case chat

        var title: String {
            switch self {
            case .terminal: return "Close terminal tab?"
            case .chat:     return "Close chat tab?"
            }
        }

        var message: String {
            switch self {
            case .terminal:
                return "This will stop the terminal session and any running process in it."
            case .chat:
                return "This will stop the chat session. The transcript remains available only if it has already been persisted."
            }
        }

        var confirmButtonTitle: String {
            switch self {
            case .terminal: return "Close Terminal"
            case .chat:     return "Close Chat"
            }
        }
    }

    static func prompt(for tab: Tab, config: AppConfig) -> Prompt? {
        switch tab {
        case .terminal:
            return config.terminal.confirmCloseTabs ? .terminal : nil
        case .acpSession:
            return config.harness.confirmCloseChatTabs ? .chat : nil
        default:
            return nil
        }
    }
}
