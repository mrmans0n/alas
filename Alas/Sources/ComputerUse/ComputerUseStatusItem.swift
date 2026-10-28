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
    private let retryStopShortcut: () -> Void
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
        retryStopShortcut: @escaping () -> Void,
        stopShortcut: @escaping () -> ShortcutBinding?
    ) {
        self.coordinator = coordinator
        self.label = { agentName($0) + " is using " + $1 }
        self.showSession = showSession
        self.stopShortcutWarning = stopShortcutWarning
        self.retryStopShortcut = retryStopShortcut
        self.stopShortcut = stopShortcut
        super.init()
    }

    /// Syncs now and re-arms observation on every change, the stop shortcut's warning included.
    func start() {
        let (driver, approvals, warning) = withObservationTracking {
            (coordinator.driver.map { ($0.sessionID, $0.app.name) }, coordinator.pendingApprovals, stopShortcutWarning())
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.start() }
        }
        apply(driver, approvals: approvals)
        item?.button?.toolTip = driver == nil ? nil : warning
    }

    /// Shown while an agent drives an app, and while an approval card waits: the card shows in
    /// its own session, which may be out of sight.
    private func apply(_ driver: (String, String)?, approvals: [ComputerUsePendingApproval]) {
        guard driver != nil || !approvals.isEmpty else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            sessionID = nil
            stopItem = nil
            warningItem = nil
            return
        }
        let statusItem = item ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item = statusItem
        sessionID = driver?.0
        statusItem.button?.image = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "Computer use")
        let menu = NSMenu()
        if let (session, appName) = driver {
            let header = NSMenuItem(title: label(session, appName), action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
        }
        // A card shows in its own session, which may be out of sight.
        for approval in approvals {
            let waiting = NSMenuItem(
                title: "Waiting for approval: \(approval.app.name) — Show", action: #selector(showApprovalAction(_:)),
                keyEquivalent: "")
            waiting.target = self
            waiting.representedObject = approval.sessionID
            menu.addItem(waiting)
        }
        guard driver != nil else {
            stopItem = nil
            warningItem = nil
            statusItem.menu = menu
            return
        }
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
    /// A shortcut another app held is tried again first, so the warning is current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        retryStopShortcut()
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

    @objc private func showApprovalAction(_ sender: NSMenuItem) {
        guard let sessionID = sender.representedObject as? String else { return }
        // The card is in Alas's window, which may be behind the app the agent is using.
        NSApp.activate()
        showSession(sessionID)
    }

    @objc private func showSessionAction() {
        if let sessionID { showSession(sessionID) }
    }

    @objc private func stopAction() {
        guard let sessionID else { return }
        Task { await coordinator.stop(sessionID: sessionID) }
    }
}
