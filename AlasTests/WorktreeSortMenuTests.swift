import Testing
@testable import Alas

@Suite
struct WorktreeSortMenuTests {
    @Test func titlesMatchTheExistingSettingsCopy() {
        #expect(WorktreeSortPresentation.title(for: .lastUpdateDesc)
            == "Last update time (most recent first)")
        #expect(WorktreeSortPresentation.title(for: .lastUpdateAsc)
            == "Last update time (least recent first)")
        #expect(WorktreeSortPresentation.title(for: .creationDesc)
            == "Creation time (newest first)")
        #expect(WorktreeSortPresentation.title(for: .creationAsc)
            == "Creation time (oldest first)")
        #expect(WorktreeSortPresentation.title(for: .branchAsc) == "Branch name")
        #expect(WorktreeSortPresentation.title(for: .manual) == "Manual")
    }

    @Test func modesFollowTheSettingsPresentationOrder() {
        #expect(WorktreeSortPresentation.modes == [
            .lastUpdateDesc,
            .lastUpdateAsc,
            .creationDesc,
            .creationAsc,
            .branchAsc,
            .manual,
        ])
    }

    @Test func visibilityIncludesHeaderHoverFocusAndMenuTracking() {
        #expect(!WorktreeSortMenu.isVisible(
            headerHovered: false, focused: false, menuTracking: false
        ))
        #expect(WorktreeSortMenu.isVisible(
            headerHovered: true, focused: false, menuTracking: false
        ))
        #expect(WorktreeSortMenu.isVisible(
            headerHovered: false, focused: true, menuTracking: false
        ))
        #expect(WorktreeSortMenu.isVisible(
            headerHovered: false, focused: false, menuTracking: true
        ))
    }
}
