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

    let isVisible: Bool
    let isEnabled: Bool
    let help: String
    let accessibilityValue: String
    let sections: [SectionDescriptor]
    let showsRecentContextLabel: Bool

    init(
        requested: Bool,
        runtimeEnabled: Bool,
        supported: Bool,
        model: LocalTextModelState,
        idle: Bool,
        phase: SessionSummaryCoordinator.Phase
    ) {
        isVisible = requested && supported
        isEnabled = isVisible && runtimeEnabled && model == .ready && idle
        help = Self.help(
            requested: requested,
            runtimeEnabled: runtimeEnabled,
            supported: supported,
            model: model,
            idle: idle
        )
        accessibilityValue = Self.accessibilityValue(
            requested: requested,
            runtimeEnabled: runtimeEnabled,
            supported: supported,
            model: model,
            idle: idle,
            phase: phase
        )

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

    private static func help(
        requested: Bool,
        runtimeEnabled: Bool,
        supported: Bool,
        model: LocalTextModelState,
        idle: Bool
    ) -> String {
        guard requested else { return "Session summaries are disabled." }
        guard supported else { return "Session summaries are not supported on this Mac." }
        switch model {
        case .unavailable:
            return "The on-device model is unavailable on this Mac."
        case .notInstalled:
            return "Install the on-device model in Settings to summarize this session."
        case .downloading:
            return "The on-device model is downloading."
        case .verifying:
            return "The on-device model is being verified."
        case .failed:
            return "The on-device model is unavailable. Retry the installation in Settings."
        case .ready:
            guard runtimeEnabled else { return "Session summaries are starting." }
            return idle
                ? "Summarize this idle session on this Mac."
                : "Wait until the session is idle to summarize it."
        }
    }

    private static func accessibilityValue(
        requested: Bool,
        runtimeEnabled: Bool,
        supported: Bool,
        model: LocalTextModelState,
        idle: Bool,
        phase: SessionSummaryCoordinator.Phase
    ) -> String {
        guard requested, supported else { return "Unavailable" }
        switch model {
        case .unavailable, .failed: return "Model unavailable"
        case .notInstalled: return "Model not installed"
        case .downloading: return "Model downloading"
        case .verifying: return "Model verifying"
        case .ready: break
        }
        guard runtimeEnabled else { return "Starting" }
        guard idle else { return "Session busy" }
        switch phase {
        case .idle: return "Ready"
        case .loading: return "Loading"
        case .result: return "Complete"
        case .failed(_, let previous):
            return previous == nil ? "Failed" : "Complete with refresh error"
        }
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
