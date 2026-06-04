import SwiftUI
import Testing
@testable import Alas

@MainActor
struct AppQuitActionTests {
    @Test func terminateSessionsCommandIsDiscoverableAndBoundToCmdOptionQ() {
        #expect(AppQuitAction.terminateSessionsTitle == "Quit and Terminate Terminal Sessions")
        #expect(AppQuitAction.terminateSessionsShortcutKey == "q")
        #expect(AppQuitAction.terminateSessionsShortcutModifiers == [.command, .option])
    }

    @Test func quitAfterTerminatingSessionsTerminatesThenQuits() {
        var events: [String] = []

        AppQuitAction.quitAfterTerminatingSessions(
            terminateSessions: {
                events.append("terminate sessions")
                return true
            },
            quitApplication: {
                events.append("quit")
            }
        )

        #expect(events == ["terminate sessions", "quit"])
    }

    @Test func quitAfterTerminatingSessionsDoesNotQuitWhenTerminationIsCancelled() {
        var events: [String] = []

        AppQuitAction.quitAfterTerminatingSessions(
            terminateSessions: {
                events.append("cancel termination")
                return false
            },
            quitApplication: {
                events.append("quit")
            }
        )

        #expect(events == ["cancel termination"])
    }
}
