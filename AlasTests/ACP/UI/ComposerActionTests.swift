import Foundation
import Testing
@testable import Alas

@Suite("ComposerAction derive function")
struct ComposerActionTests {

    // MARK: - .hidden cases

    @Test("disconnected hides the button regardless of any other state")
    func disconnectedAlwaysHidden() {
        let states: [ACPSession.StreamingState] = [.idle, .sending, .streaming, .awaitingPermission]
        for state in states {
            for hasText in [false, true] {
                for attached in [false, true] {
                    let action = composerAction(
                        streamingState: state,
                        hasText: hasText,
                        attached: attached,
                        disconnected: true
                    )
                    #expect(action == .hidden,
                            "expected .hidden for state=\(state), hasText=\(hasText), attached=\(attached), disconnected=true")
                }
            }
        }
    }

    @Test("connecting (attached==false) hides the button regardless of any other state")
    func connectingAlwaysHidden() {
        let states: [ACPSession.StreamingState] = [.idle, .sending, .streaming, .awaitingPermission]
        for state in states {
            for hasText in [false, true] {
                let action = composerAction(
                    streamingState: state,
                    hasText: hasText,
                    attached: false,
                    disconnected: false
                )
                #expect(action == .hidden,
                        "expected .hidden for state=\(state), hasText=\(hasText), attached=false")
            }
        }
    }

    @Test("idle + empty composer shows nothing")
    func idleEmptyHidden() {
        let action = composerAction(streamingState: .idle, hasText: false, attached: true, disconnected: false)
        #expect(action == .hidden)
    }

    // MARK: - .send

    @Test("idle + has text shows Send")
    func idleWithTextSends() {
        let action = composerAction(streamingState: .idle, hasText: true, attached: true, disconnected: false)
        #expect(action == .send)
    }

    // MARK: - .stop

    @Test("busy + empty composer shows Stop, for every busy state")
    func busyEmptyStops() {
        for state in [ACPSession.StreamingState.sending, .streaming, .awaitingPermission] {
            let action = composerAction(streamingState: state, hasText: false, attached: true, disconnected: false)
            #expect(action == .stop, "expected .stop for state=\(state)")
        }
    }

    // MARK: - .queue

    @Test("busy + has text shows Queue with Steer and Stop menu items, for every busy state")
    func busyWithTextQueuesWithSteerAndStopMenu() {
        for state in [ACPSession.StreamingState.sending, .streaming, .awaitingPermission] {
            let action = composerAction(streamingState: state, hasText: true, attached: true, disconnected: false)
            #expect(action == .queue(menu: [.steer, .stop]),
                    "expected .queue([.steer, .stop]) for state=\(state)")
        }
    }
}
