import Testing
@testable import Alas

@MainActor
struct WorkingTreeStageAllActionTests {
    @Test func subHeaderStagedVariantUsesStagedChevronColor() {
        // The visual change (chevron color) cannot be asserted without
        // ViewInspector-style rendering, but we can at least verify the
        // SubHeader API accepts the new `staged: true` argument without
        // changing existing default behavior.
        let header = SubHeader(
            title: "Staged",
            count: 3,
            expanded: true,
            onToggle: {},
            staged: true,
            stats: (add: 42, del: 7)
        )
        // Compile-time only: if the SubHeader API changes shape, this stops
        // compiling and the test breaks. That's the behavior we want.
        _ = header
    }

    @Test func subHeaderDefaultsStillCompile() {
        // Existing call sites must keep working without specifying the new
        // optional params.
        let header = SubHeader(
            title: "Changes",
            count: 5,
            expanded: true,
            onToggle: {}
        )
        _ = header
    }

    @Test func sectionHeaderAcceptsStatsTuple() {
        let header = SectionHeader(
            role: .commits,
            title: "Commits",
            count: 12,
            expanded: true,
            stats: (add: 100, del: 8),
            onToggle: {}
        )
        _ = header
    }
}
