import Foundation
import Observation

@MainActor
@Observable
public final class EditorCommandAvailability {
    public static let shared = EditorCommandAvailability()

    private weak var activeRouter: EditorCommandRouter?
    public private(set) var activeEditor = false
    public private(set) var available: Set<EditorCommandID> = []

    public func activate(_ router: EditorCommandRouter) {
        activeRouter = router
        activeEditor = true
        refresh(router)
    }

    public func deactivate(_ router: EditorCommandRouter) {
        guard activeRouter === router else { return }
        clear()
    }

    public func clear() {
        activeRouter = nil
        activeEditor = false
        available = []
    }

    public func refresh(_ router: EditorCommandRouter) {
        guard activeRouter === router else { return }
        available = Set(router.availableCommands())
    }

    public func isAvailable(_ command: EditorCommandID) -> Bool {
        available.contains(command)
    }

    public init() {}
}

@MainActor
public final class EditorCommandRouter {
    public typealias Handler = (NSRange) -> Void

    private var capabilities: LSPCapabilities
    private var isServerReady: Bool
    private var handlers: [EditorCommandID: Handler]
    private var availabilityChecks: [EditorCommandID: () -> Bool] = [:]

    public init(
        capabilities: LSPCapabilities = .empty,
        isServerReady: Bool = false,
        handlers: [EditorCommandID: Handler] = [:]
    ) {
        self.capabilities = capabilities
        self.isServerReady = isServerReady
        self.handlers = handlers
    }

    public func update(capabilities: LSPCapabilities, isServerReady: Bool) {
        self.capabilities = capabilities
        self.isServerReady = isServerReady
        EditorCommandAvailability.shared.refresh(self)
    }

    public func register(
        _ command: EditorCommandID,
        isAvailable: @escaping () -> Bool = { true },
        handler: @escaping Handler
    ) {
        handlers[command] = handler
        availabilityChecks[command] = isAvailable
        EditorCommandAvailability.shared.refresh(self)
    }

    public func availableCommands() -> [EditorCommandID] {
        EditorCommandID.allCases.filter { command in
            guard handlers[command] != nil else { return false }
            guard availabilityChecks[command]?() ?? true else { return false }
            if Self.localCommands.contains(command) { return true }
            return isServerReady && capabilities.supports(command)
        }
    }

    public func registerCodeActions(isAvailable: @escaping () -> Bool, handler: @escaping Handler) {
        register(.codeActions, isAvailable: isAvailable, handler: handler)
    }

    public func isSupported(_ command: EditorCommandID) -> Bool {
        capabilities.supports(command)
    }

    public var serverIsReady: Bool { isServerReady }

    public func refreshAvailability() {
        EditorCommandAvailability.shared.refresh(self)
    }

    public func invoke(_ command: EditorCommandID, range: NSRange) {
        guard availableCommands().contains(command) else { return }
        handlers[command]?(range)
    }

    public static func targetRange(clickOffset: Int, selection: NSRange) -> NSRange {
        guard selection.location != NSNotFound,
              NSLocationInRange(clickOffset, selection)
        else {
            return NSRange(location: clickOffset, length: 0)
        }
        return selection
    }

    private static let localCommands: Set<EditorCommandID> = [.back, .forward, .nextProblem, .previousProblem]
}
