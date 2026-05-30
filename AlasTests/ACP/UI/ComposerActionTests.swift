import Testing
@testable import Alas

@Suite("ComposerAction derive function")
struct ComposerActionTests {
    // MARK: - Agent lifecycle

    @Test("idle streaming + text shows Send for every agent lifecycle state")
    func idleWithTextSendsForEveryAgentState() {
        for agentState in agentStates {
            let action = composerAction(
                streamingState: .idle,
                hasText: true,
                agentState: agentState
            )
            #expect(action == .send, "expected .send for agentState=\(agentState)")
        }
    }

    @Test("idle streaming + empty composer hides the action for every agent lifecycle state")
    func idleEmptyHiddenForEveryAgentState() {
        for agentState in agentStates {
            let action = composerAction(
                streamingState: .idle,
                hasText: false,
                agentState: agentState
            )
            #expect(action == .hidden, "expected .hidden for agentState=\(agentState)")
        }
    }

    // MARK: - .hidden

    @Test("idle + empty composer shows nothing")
    func idleEmptyHidden() {
        let action = composerAction(streamingState: .idle, hasText: false, agentState: .ready)
        #expect(action == .hidden)
    }

    // MARK: - .send

    @Test("idle + has text shows Send")
    func idleWithTextSends() {
        let action = composerAction(streamingState: .idle, hasText: true, agentState: .ready)
        #expect(action == .send)
    }

    // MARK: - .stop

    @Test("busy + empty composer shows Stop, for every busy state")
    func busyEmptyStops() {
        for state in busyStates {
            for agentState in agentStates {
                let action = composerAction(
                    streamingState: state,
                    hasText: false,
                    agentState: agentState
                )
                #expect(action == .stop, "expected .stop for state=\(state), agentState=\(agentState)")
            }
        }
    }

    // MARK: - .queue

    @Test("busy + has text shows Queue with Steer and Stop menu items, for every busy state")
    func busyWithTextQueuesWithSteerAndStopMenu() {
        for state in busyStates {
            for agentState in agentStates {
                let action = composerAction(
                    streamingState: state,
                    hasText: true,
                    agentState: agentState
                )
                #expect(action == .queue(menu: [.steer, .stop]),
                        "expected .queue([.steer, .stop]) for state=\(state), agentState=\(agentState)")
            }
        }
    }

    @Test("primary submit intent preserves Option-click steer shortcut")
    func primarySubmitIntentPreservesOptionClickSteer() {
        #expect(primarySubmitIntent(for: .send, optionPressed: false) == .auto)
        #expect(primarySubmitIntent(for: .send, optionPressed: true) == .steer)
        #expect(primarySubmitIntent(for: .queue(menu: [.steer, .stop]), optionPressed: false) == .auto)
        #expect(primarySubmitIntent(for: .queue(menu: [.steer, .stop]), optionPressed: true) == .steer)
    }

    @Test("primary submit intent is absent for non-submit actions")
    func primarySubmitIntentAbsentForNonSubmitActions() {
        #expect(primarySubmitIntent(for: .stop, optionPressed: true) == nil)
        #expect(primarySubmitIntent(for: .hidden, optionPressed: true) == nil)
    }

    private var busyStates: [ACPSession.StreamingState] {
        [.sending, .streaming, .awaitingPermission]
    }

    private var agentStates: [ACPSession.AgentState] {
        [.idle, .spawning, .ready, .disconnected, .failed("boom")]
    }
}
