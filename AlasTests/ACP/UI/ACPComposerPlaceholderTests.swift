import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACPInputField placeholder")
struct ACPComposerPlaceholderTests {
    @Test("idle ignores sendOnEnter and shows the default prompt")
    func idle() {
        #expect(ACPInputField.placeholder(for: .idle, sendOnEnter: true)
                == "Plan, ask, or build — type / for commands")
        #expect(ACPInputField.placeholder(for: .idle, sendOnEnter: false)
                == "Plan, ask, or build — type / for commands")
    }

    @Test("busy placeholder advertises the default and the actual steering behavior", arguments: [
        (true, "Queue a follow-up… (⌥⏎ to steer)", "Steer… (⌥⏎ to queue)"),
        (false, "Queue a follow-up… (⌥⏎ to interrupt & send)", "Interrupt & send… (⌥⏎ to queue)")
    ])
    func busyMapping(nativeSteering: Bool, queueText: String, steerText: String) {
        for state in [ACPSession.StreamingState.sending, .streaming, .awaitingPermission, .awaitingInput] {
            #expect(ACPInputField.placeholder(for: state, sendOnEnter: true, nativeSteering: nativeSteering) == queueText)
            #expect(ACPInputField.placeholder(for: state, sendOnEnter: false, nativeSteering: nativeSteering) == steerText)
        }
    }
}
