import Foundation
import Observation

@MainActor
@Observable
final class EditorCommandAvailability {
    static let shared = EditorCommandAvailability()

    private weak var activeRouter: EditorCommandRouter?
    private(set) var activeEditor = false
    private(set) var available: Set<EditorCommandID> = []

    func activate(_ router: EditorCommandRouter) {
        activeRouter = router
        activeEditor = true
        refresh(router)
    }

    func deactivate(_ router: EditorCommandRouter) {
        guard activeRouter === router else { return }
        activeRouter = nil
        activeEditor = false
        available = []
    }

    func refresh(_ router: EditorCommandRouter) {
        guard activeRouter === router else { return }
        available = Set(router.availableCommands())
    }

    func isAvailable(_ command: EditorCommandID) -> Bool {
        available.contains(command)
    }
}

@MainActor
final class EditorCommandRouter {
    typealias Handler = (NSRange) -> Void

    private var capabilities: LSPCapabilities
    private var isServerReady: Bool
    private var handlers: [EditorCommandID: Handler]

    init(
        capabilities: LSPCapabilities = .empty,
        isServerReady: Bool = false,
        handlers: [EditorCommandID: Handler] = [:]
    ) {
        self.capabilities = capabilities
        self.isServerReady = isServerReady
        self.handlers = handlers
    }

    func update(capabilities: LSPCapabilities, isServerReady: Bool) {
        self.capabilities = capabilities
        self.isServerReady = isServerReady
        EditorCommandAvailability.shared.refresh(self)
    }

    func register(_ command: EditorCommandID, handler: @escaping Handler) {
        handlers[command] = handler
        EditorCommandAvailability.shared.refresh(self)
    }

    func availableCommands() -> [EditorCommandID] {
        EditorCommandID.allCases.filter { command in
            isServerReady && capabilities.supports(command) && handlers[command] != nil
        }
    }

    func isSupported(_ command: EditorCommandID) -> Bool {
        capabilities.supports(command)
    }

    var serverIsReady: Bool { isServerReady }

    func invoke(_ command: EditorCommandID, range: NSRange) {
        guard availableCommands().contains(command) else { return }
        handlers[command]?(range)
    }

    static func targetRange(clickOffset: Int, selection: NSRange) -> NSRange {
        guard selection.location != NSNotFound,
              NSLocationInRange(clickOffset, selection)
        else {
            return NSRange(location: clickOffset, length: 0)
        }
        return selection
    }
}
