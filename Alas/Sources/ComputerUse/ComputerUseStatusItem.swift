import AppKit
import Observation

/// Menu-bar item present only while an agent is driving an app.
@MainActor
final class ComputerUseStatusItem: NSObject {
    private let coordinator: ComputerUseCoordinator
    private let label: (String, String) -> String
    private let showSession: (String) -> Void
    private var item: NSStatusItem?
    private var sessionID: String?

    init(
        coordinator: ComputerUseCoordinator,
        agentName: @escaping (String) -> String,
        showSession: @escaping (String) -> Void
    ) {
        self.coordinator = coordinator
        self.label = { agentName($0) + " is using " + $1 }
        self.showSession = showSession
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
        menu.addItem(stop)
        statusItem.menu = menu
    }

    @objc private func showSessionAction() {
        if let sessionID { showSession(sessionID) }
    }

    @objc private func stopAction() {
        guard let sessionID else { return }
        Task { await coordinator.stop(sessionID: sessionID) }
    }
}
