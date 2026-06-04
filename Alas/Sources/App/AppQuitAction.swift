import AppKit
import SwiftUI

enum AppQuitAction {
    static let terminateSessionsTitle = "Quit and Terminate Terminal Sessions"
    static let terminateSessionsShortcutKey: KeyEquivalent = "q"
    static let terminateSessionsShortcutModifiers: EventModifiers = [.command, .option]

    @MainActor
    static func quitAfterTerminatingSessions(
        terminateSessions: () -> Bool,
        quitApplication: () -> Void = { NSApp.terminate(nil) }
    ) {
        guard terminateSessions() else { return }
        quitApplication()
    }
}
