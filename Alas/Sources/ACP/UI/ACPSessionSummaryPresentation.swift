import Foundation

enum ACPSessionSummaryBindingPolicy {
    struct Input: Equatable {
        let requested: Bool
        let supported: Bool
        let incarnation: UUID

        var isActive: Bool { requested && supported }
    }

    enum Action: Equatable {
        case none
        case bind
        case teardown
    }

    static func action(from previous: Input?, to current: Input) -> Action {
        guard current.isActive else {
            return previous?.isActive == true ? .teardown : .none
        }
        guard previous?.isActive == true,
              previous?.incarnation == current.incarnation else { return .bind }
        return .none
    }
}

struct ACPSessionSummaryPresentation: Equatable {
    struct SectionDescriptor: Equatable, Identifiable {
        enum Kind: String {
            case goal = "Goal"
            case completed = "Completed"
            case blockers = "Blockers"
            case nextAction = "Next action"
        }

        let kind: Kind
        let items: [String]

        var id: Kind { kind }
        var title: String { kind.rawValue }
    }

    static let help = "Summarize this idle session on this Mac."

    /// Only shown when a click can actually summarize; there is no disabled state.
    let isVisible: Bool
    let accessibilityValue: String
    let sections: [SectionDescriptor]
    let showsRecentContextLabel: Bool

    init(
        requested: Bool,
        runtimeEnabled: Bool,
        supported: Bool,
        model: LocalTextModelState,
        idle: Bool,
        hasCompleteTurn: Bool,
        phase: SessionSummaryCoordinator.Phase
    ) {
        isVisible = requested && supported && runtimeEnabled && model == .ready && idle && hasCompleteTurn
        accessibilityValue = switch phase {
        case .idle: "Ready"
        case .loading: "Loading"
        case .result: "Complete"
        case .failed(_, let previous): previous == nil ? "Failed" : "Complete with refresh error"
        }

        let summary: SessionSummary? = switch phase {
        case .result(let summary): summary
        case .failed(_, let previous): previous
        case .idle, .loading: nil
        }
        sections = Self.sections(for: summary)
        showsRecentContextLabel = summary?.isPartial == true
    }

    static func popoverOpenAfterGenerationChange(wasOpen: Bool) -> Bool {
        false
    }

    private static func sections(for summary: SessionSummary?) -> [SectionDescriptor] {
        guard let summary else { return [] }
        var sections: [SectionDescriptor] = []
        append(.goal, [summary.goal].compactMap(trimmed), to: &sections)
        append(.completed, summary.completed.compactMap(trimmed), to: &sections)
        append(.blockers, summary.blockers.compactMap(trimmed), to: &sections)
        append(.nextAction, [summary.nextAction].compactMap(trimmed), to: &sections)
        return sections
    }

    private static func append(
        _ kind: SectionDescriptor.Kind,
        _ items: [String],
        to sections: inout [SectionDescriptor]
    ) {
        guard !items.isEmpty else { return }
        sections.append(.init(kind: kind, items: items))
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
