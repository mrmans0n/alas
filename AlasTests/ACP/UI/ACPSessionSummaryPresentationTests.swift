import Testing
@testable import Alas

@Suite("ACPSessionSummaryPresentation")
struct ACPSessionSummaryPresentationTests {
    @Test func hiddenWhenDisabledOrUnsupported() {
        #expect(!ACPSessionSummaryPresentation(
            requested: false,
            runtimeEnabled: false,
            supported: true,
            model: .ready,
            idle: true,
            phase: .idle
        ).isVisible)
        #expect(!ACPSessionSummaryPresentation(
            requested: true,
            runtimeEnabled: true,
            supported: false,
            model: .ready,
            idle: true,
            phase: .idle
        ).isVisible)
    }

    @Test func visibleButDisabledWhileModelUnavailableOrSessionBusy() {
        let unavailable = ACPSessionSummaryPresentation(
            requested: true,
            runtimeEnabled: false,
            supported: true,
            model: .notInstalled,
            idle: true,
            phase: .idle
        )
        #expect(unavailable.isVisible)
        #expect(!unavailable.isEnabled)
        #expect(unavailable.help == "Install the on-device model in Settings to summarize this session.")

        let busy = ACPSessionSummaryPresentation(
            requested: true,
            runtimeEnabled: true,
            supported: true,
            model: .ready,
            idle: false,
            phase: .idle
        )
        #expect(busy.isVisible)
        #expect(!busy.isEnabled)
        #expect(busy.help == "Wait until the session is idle to summarize it.")
    }

    @Test func requestedCapabilityStaysVisibleWhileRuntimeAndModelAreNotReady() {
        let presentation = ACPSessionSummaryPresentation(
            requested: true,
            runtimeEnabled: false,
            supported: true,
            model: .downloading(received: 50, expected: 100),
            idle: true,
            phase: .idle
        )

        #expect(presentation.isVisible)
        #expect(!presentation.isEnabled)
        #expect(presentation.help == "The on-device model is downloading.")
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

        #expect(presentation(phase: .result(summary)).sections == [
            .init(kind: .completed, items: ["Implemented toolbar"]),
            .init(kind: .nextAction, items: ["Run focused tests"])
        ])
    }

    @Test func partialResultAddsRecentContextLabel() {
        let summary = SessionSummary(
            goal: "Ship search",
            completed: [],
            blockers: [],
            nextAction: nil,
            isPartial: true
        )

        #expect(presentation(phase: .result(summary)).showsRecentContextLabel)
    }

    @Test func presentationGenerationForcesPopoverClosed() {
        #expect(!ACPSessionSummaryPresentation.popoverOpenAfterGenerationChange(wasOpen: true))
        #expect(!ACPSessionSummaryPresentation.popoverOpenAfterGenerationChange(wasOpen: false))
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
            phase: phase
        )
    }
}
