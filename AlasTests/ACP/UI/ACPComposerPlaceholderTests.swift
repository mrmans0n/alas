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

    @Test("busy + sendOnEnter advertises ⏎ as queue and ⌥⏎ as steer")
    func busyDefault() {
        let queueText = "Queue a follow-up… (⌥⏎ to steer)"
        for state in [ACPSession.StreamingState.sending, .streaming, .awaitingPermission] {
            #expect(ACPInputField.placeholder(for: state, sendOnEnter: true) == queueText)
        }
    }

    @Test("busy + inverted mapping advertises ⏎ as steer and ⌥⏎ as queue")
    func busyInverted() {
        let steerText = "Steer the agent… (⌥⏎ to queue)"
        for state in [ACPSession.StreamingState.sending, .streaming, .awaitingPermission] {
            #expect(ACPInputField.placeholder(for: state, sendOnEnter: false) == steerText)
        }
    }
}
