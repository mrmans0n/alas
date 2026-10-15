import Foundation
import Testing
@testable import Alas

@Suite("ACPSessionSummaryPresentation")
struct ACPSessionSummaryPresentationTests {
    @Test func bindingRequiresRequestedAndSupportedCapability() {
        let incarnation = UUID()
        let inactive = ACPSessionSummaryBindingPolicy.Input(
            requested: false,
            supported: true,
            incarnation: incarnation
        )
        let active = ACPSessionSummaryBindingPolicy.Input(
            requested: true,
            supported: true,
            incarnation: incarnation
        )

        #expect(ACPSessionSummaryBindingPolicy.action(from: nil, to: inactive) == .none)
        #expect(ACPSessionSummaryBindingPolicy.action(from: nil, to: active) == .bind)
        #expect(ACPSessionSummaryBindingPolicy.action(from: inactive, to: active) == .bind)
        #expect(ACPSessionSummaryBindingPolicy.action(from: active, to: inactive) == .teardown)
        #expect(ACPSessionSummaryBindingPolicy.action(from: active, to: active) == .none)
        #expect(ACPSessionSummaryBindingPolicy.action(
            from: active,
            to: .init(requested: true, supported: true, incarnation: UUID())
        ) == .bind)
        #expect(ACPSessionSummaryBindingPolicy.action(
            from: inactive,
            to: .init(requested: true, supported: false, incarnation: UUID())
        ) == .none)
    }

    @Test func visibleOnlyWhenAClickCanSummarize() {
        #expect(presentation(phase: .idle).isVisible)
    }

    @Test(arguments: ["requested", "supported", "runtime", "model", "idle", "turn"])
    func hiddenWhenAnyPreconditionFails(_ failing: String) {
        #expect(!ACPSessionSummaryPresentation(
            requested: failing != "requested",
            runtimeEnabled: failing != "runtime",
            supported: failing != "supported",
            model: failing == "model" ? .downloading(received: 50, expected: 100) : .ready,
            idle: failing != "idle",
            hasCompleteTurn: failing != "turn",
            phase: .idle
        ).isVisible)
    }

    @Test func loadingResultFirstFailureAndRefreshFailureMapToDistinctAccessibleStatus() {
        let summary = SessionSummary(
            goal: "Ship search",
            completed: ["Added indexing"],
            blockers: [],
            nextAction: "Run tests",
            isPartial: false
        )

        #expect(presentation(phase: .loading).accessibilityValue == "Loading")
        #expect(presentation(phase: .result(summary)).accessibilityValue == "Complete")
        #expect(presentation(phase: .failed("Generation failed", previous: nil)).accessibilityValue == "Failed")
        #expect(presentation(
            phase: .failed("Refresh failed", previous: summary)
        ).accessibilityValue == "Complete with refresh error")
    }

    @Test func omitsEmptyOptionalSections() {
        let summary = SessionSummary(
            goal: "  ",
            completed: ["Implemented toolbar", ""],
            blockers: [],
            nextAction: "Run focused tests",
            isPartial: false
        )

        #expect(ACPSessionSummaryPresentation.cardContent(cardMode: .manual, phase: .result(summary)) == .sections([
            .init(kind: .completed, items: ["Implemented toolbar"]),
            .init(kind: .nextAction, items: ["Run focused tests"])
        ], recentContext: false))
    }

    private static let partialSummary = SessionSummary(
        goal: "Ship search",
        completed: [],
        blockers: [],
        nextAction: nil,
        isPartial: true
    )

    @Test(arguments: [
        (nil, .result(partialSummary), .hidden),
        (.recap, .loading, .loading),
        (.recap, .result(partialSummary), .sections([.init(kind: .goal, items: ["Ship search"])], recentContext: true)),
        (.manual, .failed("Generation failed", previous: nil), .failed("Generation failed")),
        (.recap, .idle, .hidden),
        // The user clicked, so a blank card would look like a dead button.
        (.manual, .loading, .loading),
    ] as [(SessionSummaryRequestMode?, SessionSummaryCoordinator.Phase, ACPSessionSummaryPresentation.CardContent)])
    func cardContentFollowsModeAndPhase(
        _ mode: SessionSummaryRequestMode?,
        _ phase: SessionSummaryCoordinator.Phase,
        _ expected: ACPSessionSummaryPresentation.CardContent
    ) {
        #expect(ACPSessionSummaryPresentation.cardContent(cardMode: mode, phase: phase) == expected)
    }

    private func presentation(
        phase: SessionSummaryCoordinator.Phase
    ) -> ACPSessionSummaryPresentation {
        ACPSessionSummaryPresentation(
            requested: true,
            runtimeEnabled: true,
            supported: true,
            model: .ready,
            idle: true,
            hasCompleteTurn: true,
            phase: phase
        )
    }
}
