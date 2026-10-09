import Foundation

enum CloseTabConfirmationPolicy {
    enum Prompt: Equatable {
        case terminal
        case chat
        /// A chat tab open on a paired Mac, named here.
        case peerChat(peerName: String)

        var title: String {
            switch self {
            case .terminal: return "Close terminal tab?"
            case .chat, .peerChat: return "Close chat tab?"
            }
        }

        var message: String {
            switch self {
            case .terminal:
                return "This will stop the terminal session and any running process in it."
            case .chat:
                return "This will stop the chat session. The transcript remains available only if it has already been persisted."
            case .peerChat(let peerName):
                return "This will stop the chat session on \(peerName)."
            }
        }

        var confirmButtonTitle: String {
            switch self {
            case .terminal: return "Close Terminal"
            case .chat, .peerChat: return "Close Chat"
            }
        }
    }

    static func peerSessionPrompt(peerName: String, config: AppConfig) -> Prompt? {
        config.harness.confirmCloseChatTabs ? .peerChat(peerName: peerName) : nil
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
