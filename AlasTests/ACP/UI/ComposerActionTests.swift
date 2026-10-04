import Foundation
import Testing
@testable import Alas

@Suite("ComposerAction derive function")
struct ComposerActionTests {
    @Test("idle background work offers Stop while preserving Send for a typed prompt", arguments: [false, true])
    func idleBackgroundWork(hasText: Bool) {
        #expect(composerAction(streamingState: .idle, hasText: hasText, agentState: .ready,
            hasCancellableBackgroundWork: true) == (hasText ? .send : .stop))
    }

    @Test("schedule presets use the local calendar and round later today up to 30 minutes")
    func schedulePresets() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 10, hour: 14, minute: 10
        ))!

        #expect(ACPSchedulePreset.laterToday.date(after: now, calendar: calendar)
            == calendar.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 16, minute: 30)))
        #expect(ACPSchedulePreset.tomorrowMorning.date(after: now, calendar: calendar)
            == calendar.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 9)))
        #expect(ACPSchedulePreset.nextMondayMorning.date(after: now, calendar: calendar)
            == calendar.date(from: DateComponents(year: 2026, month: 9, day: 14, hour: 9)))
    }

    @Test("later today is unavailable when two rounded hours cross midnight")
    func laterTodayDoesNotCrossMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 10, hour: 22, minute: 15
        ))!

        #expect(ACPSchedulePreset.laterToday.date(after: now, calendar: calendar) == nil)
    }

    @Test("morning presets retain their wall-clock time across daylight saving changes")
    func morningPresetsAreDSTSafe() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let now = calendar.date(from: DateComponents(
            year: 2026, month: 3, day: 7, hour: 12
        ))!

        #expect(ACPSchedulePreset.tomorrowMorning.date(after: now, calendar: calendar)
            == calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 9)))
    }

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

    @Test("busy menu exposes the alternate action and Stop", arguments: [true, false])
    func busyMenuExposesAlternateAction(queueByDefault: Bool) {
        for state in busyStates {
            for agentState in agentStates {
                let action = composerAction(
                    streamingState: state,
                    hasText: true,
                    agentState: agentState,
                    queueByDefault: queueByDefault
                )
                #expect(action == .queue(menu: queueByDefault ? [.steer, .stop] : [.queue, .stop]))
            }
        }
    }

    @Test("busy primary action follows the preference and Option chooses the alternate", arguments: [true, false])
    func primarySubmitIntentFollowsPreference(queueByDefault: Bool) {
        #expect(primarySubmitIntent(for: .send, optionPressed: false) == .auto)
        #expect(primarySubmitIntent(for: .send, optionPressed: true) == .steer)
        #expect(primarySubmitIntent(for: .queue(menu: [.steer, .stop]), optionPressed: false,
                                    queueByDefault: queueByDefault) == (queueByDefault ? .auto : .steer))
        #expect(primarySubmitIntent(for: .queue(menu: [.steer, .stop]), optionPressed: true,
                                    queueByDefault: queueByDefault) == (queueByDefault ? .steer : .auto))
    }

    @Test("primary submit intent is absent for non-submit actions")
    func primarySubmitIntentAbsentForNonSubmitActions() {
        #expect(primarySubmitIntent(for: .stop, optionPressed: true) == nil)
        #expect(primarySubmitIntent(for: .hidden, optionPressed: true) == nil)
    }

    private var busyStates: [ACPSession.StreamingState] {
        [.sending, .streaming, .awaitingPermission, .awaitingInput]
    }

    private var agentStates: [ACPSession.AgentState] {
        [.idle, .spawning, .ready, .disconnected, .failed("boom")]
    }
}
