import Foundation

/// Mutually-exclusive states the composer's single action button can be in.
/// Derived from `(streamingState, hasText, agentState)` via
/// `composerAction(...)`. The view layer renders one capsule per case.
enum ComposerAction: Equatable {
    /// Nothing to do — render nothing. Composer toolbar reflows naturally.
    case hidden
    /// Idle agent + non-empty composer. Tapping submits the prompt.
    case send
    /// Busy agent + non-empty composer. Primary action enqueues the prompt;
    /// the menu exposes steer and stop.
    case queue(menu: [ComposerMenuItem])
    /// Busy agent + empty composer. Tapping cancels the in-flight turn.
    case stop
}

/// Items that appear in the chevron menu when `ComposerAction == .queue`.
/// Ordered as they appear top-to-bottom in the menu.
enum ComposerMenuItem: Hashable {
    case steer
    case stop
}

enum ACPSchedulePreset: CaseIterable, Identifiable {
    case laterToday
    case tomorrowMorning
    case nextMondayMorning

    var id: Self { self }

    var title: String {
        switch self {
        case .laterToday: "Later today"
        case .tomorrowMorning: "Tomorrow at 9:00 AM"
        case .nextMondayMorning: "Next Monday at 9:00 AM"
        }
    }

    func date(after now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .laterToday:
            guard let twoHoursLater = calendar.date(byAdding: .hour, value: 2, to: now) else { return nil }
            let start = calendar.startOfDay(for: twoHoursLater)
            let components = calendar.dateComponents([.hour, .minute], from: twoHoursLater)
            let minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
            guard let rounded = calendar.date(byAdding: .minute, value: ((minutes + 29) / 30) * 30, to: start),
                  calendar.isDate(rounded, inSameDayAs: now)
            else { return nil }
            return rounded
        case .tomorrowMorning:
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else { return nil }
            return calendar.date(byAdding: .hour, value: 9, to: calendar.startOfDay(for: tomorrow))
        case .nextMondayMorning:
            let weekday = calendar.component(.weekday, from: now)
            let days = (9 - weekday) % 7
            guard let monday = calendar.date(byAdding: .day, value: days == 0 ? 7 : days, to: now) else { return nil }
            return calendar.date(byAdding: .hour, value: 9, to: calendar.startOfDay(for: monday))
        }
    }
}

/// Pure derive — no SwiftUI imports, no session/runner references.
/// Exhaustively unit-tested in `ComposerActionTests`.
///
/// The agent lifecycle intentionally does not disable or hide a non-empty
/// composer: `ACPSessionManager.submit` accepts prompts while disconnected,
/// failed, idle, or spawning so the user's prompt can kick recovery.
func composerAction(
    streamingState: ACPSession.StreamingState,
    hasText: Bool,
    agentState: ACPSession.AgentState
) -> ComposerAction {
    switch agentState {
    case .idle, .spawning, .ready, .disconnected, .failed(_):
        break
    }

    switch streamingState {
    case .idle:
        return hasText ? .send : .hidden
    case .sending, .streaming, .awaitingPermission, .awaitingInput:
        return hasText ? .queue(menu: [.steer, .stop]) : .stop
    }
}

func primarySubmitIntent(for action: ComposerAction, optionPressed: Bool) -> ACPSubmitIntent? {
    switch action {
    case .send, .queue:
        optionPressed ? .steer : .auto
    case .stop, .hidden:
        nil
    }
}
