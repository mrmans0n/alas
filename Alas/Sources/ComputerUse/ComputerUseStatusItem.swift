import AlasCore
import AppKit
import Observation

/// Menu-bar item present only while an agent is driving an app.
@MainActor
final class ComputerUseStatusItem: NSObject, NSMenuDelegate {
    private let coordinator: ComputerUseCoordinator
    private let label: (String, String) -> String
    private let showSession: (String) -> Void
    private let stopShortcutWarning: () -> String?
    private let stopShortcut: () -> ShortcutBinding?
    private var warningItem: NSMenuItem?
    private var stopItem: NSMenuItem?
    private var item: NSStatusItem?
    private var sessionID: String?

    init(
        coordinator: ComputerUseCoordinator,
        agentName: @escaping (String) -> String,
        showSession: @escaping (String) -> Void,
        stopShortcutWarning: @escaping () -> String?,
        stopShortcut: @escaping () -> ShortcutBinding?
    ) {
        self.coordinator = coordinator
        self.label = { agentName($0) + " is using " + $1 }
        self.showSession = showSession
        self.stopShortcutWarning = stopShortcutWarning
        self.stopShortcut = stopShortcut
        super.init()
    }

    /// Syncs now and re-arms observation on every change.
    func start() {
        let driver = withObservationTracking {
            coordinator.driver.map { ($0.sessionID, $0.app.name) }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.start() }
        }
        apply(driver)
    }

    private func apply(_ driver: (String, String)?) {
        guard let (session, appName) = driver else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            sessionID = nil
            return
        }
        let statusItem = item ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item = statusItem
        sessionID = session
        statusItem.button?.image = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "Computer use")
        let menu = NSMenu()
        let header = NSMenuItem(title: label(session, appName), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let show = NSMenuItem(title: "Show Session", action: #selector(showSessionAction), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        menu.addItem(.separator())
        let stop = NSMenuItem(title: "Stop", action: #selector(stopAction), keyEquivalent: "")
        stop.target = self
        Self.showShortcut(stopShortcut(), on: stop)
        menu.addItem(stop)
        stopItem = stop
        let warning = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        warning.isEnabled = false
        warning.isHidden = true
        menu.addItem(warning)
        warningItem = warning
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Read when the menu opens: the hot key registers after the driver changes, so the menu
    /// built on that change can't know yet whether it succeeded.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let warning = stopShortcutWarning()
        warningItem?.title = warning ?? ""
        warningItem?.isHidden = warning == nil
        if let stopItem { Self.showShortcut(stopShortcut(), on: stopItem) }
    }

    /// Shows the stop shortcut next to Stop; the system-wide hot key is what acts on it.
    private static func showShortcut(_ binding: ShortcutBinding?, on item: NSMenuItem) {
        let equivalent = binding.flatMap(menuKeyEquivalent)
        item.keyEquivalent = equivalent?.key ?? ""
        item.keyEquivalentModifierMask = equivalent?.modifiers ?? []
    }

    /// The binding as AppKit spells a menu item's key equivalent; nil for a key it can't show.
    static func menuKeyEquivalent(_ binding: ShortcutBinding) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
        let named: [String: Int] = [
            "return": 0x0D, "tab": 0x09, "space": 0x20, "delete": 0x08, "escape": 0x1B,
            "leftArrow": NSLeftArrowFunctionKey, "rightArrow": NSRightArrowFunctionKey,
            "upArrow": NSUpArrowFunctionKey, "downArrow": NSDownArrowFunctionKey,
        ]
        let key: String
        if let code = named[binding.key], let scalar = UnicodeScalar(code) {
            key = String(Character(scalar))
        } else if binding.key.count == 1 {
            // An uppercase letter would read as Shift too.
            key = binding.key.lowercased()
        } else {
            return nil
        }
        var modifiers: NSEvent.ModifierFlags = []
        for modifier in binding.modifiers {
            switch modifier {
            case .command: modifiers.insert(.command)
            case .shift: modifiers.insert(.shift)
            case .option: modifiers.insert(.option)
            case .control: modifiers.insert(.control)
            }
        }
        return (key, modifiers)
    }

    @objc private func showSessionAction() {
        if let sessionID { showSession(sessionID) }
    }

    @objc private func stopAction() {
        guard let sessionID else { return }
        Task { await coordinator.stop(sessionID: sessionID) }
    }
}
