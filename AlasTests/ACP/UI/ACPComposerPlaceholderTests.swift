import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACPInputField placeholder")
struct ACPComposerPlaceholderTests {
    @Test("idle ignores sendOnEnter and shows the default prompt")
    func idle() {
        #expect(ACPInputField.placeholder(for: .idle, sendOnEnter: true)
                == "Plan, ask, or build — type / for commands, ⇧⏎ for a new line")
        #expect(ACPInputField.placeholder(for: .idle, sendOnEnter: false)
                == "Plan, ask, or build — type / for commands, ⇧⏎ for a new line")
    }

    @Test("busy placeholder advertises the default and the actual steering behavior", arguments: [
        (true, "Queue a follow-up… (⌥⏎ to steer, ⇧⏎ for a new line)", "Steer… (⌥⏎ to queue, ⇧⏎ for a new line)"),
        (false, "Queue a follow-up… (⌥⏎ to interrupt & send, ⇧⏎ for a new line)", "Interrupt & send… (⌥⏎ to queue, ⇧⏎ for a new line)")
    ])
    func busyMapping(nativeSteering: Bool, queueText: String, steerText: String) {
        for state in [ACPSession.StreamingState.sending, .streaming, .awaitingPermission, .awaitingInput] {
            #expect(ACPInputField.placeholder(for: state, sendOnEnter: true, nativeSteering: nativeSteering) == queueText)
            #expect(ACPInputField.placeholder(for: state, sendOnEnter: false, nativeSteering: nativeSteering) == steerText)
        }
    }
}
