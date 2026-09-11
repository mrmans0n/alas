import Testing
@testable import Alas

struct RightPaneTabBarLayoutTests {
    @Test func compactRailShowsTheActiveTabLabelOnly() {
        #expect(RightPaneTabBarLayout.compact.showsLabel(for: .changes, activeTab: .changes))
        #expect(!RightPaneTabBarLayout.compact.showsLabel(for: .files, activeTab: .changes))
        #expect(!RightPaneTabBarLayout.compact.showsLabel(for: .changes, activeTab: .files))
        #expect(RightPaneTabBarLayout.compact.showsLabel(for: .files, activeTab: .files))
        #expect(!RightPaneTabBarLayout.iconOnly.showsLabel(for: .changes, activeTab: .changes))
        #expect(!RightPaneTabBarLayout.iconOnly.showsLabel(for: .files, activeTab: .files))
    }

    @Test func compactRailShowsCountsOnlyForTheActiveTab() {
        #expect(RightPaneTabBarLayout.compact.showsCount(for: .changes, activeTab: .changes))
        #expect(!RightPaneTabBarLayout.compact.showsCount(for: .changes, activeTab: .files))
        #expect(RightPaneTabBarLayout.compact.showsCount(for: .run, activeTab: .run))
        #expect(!RightPaneTabBarLayout.compact.showsCount(for: .run, activeTab: .changes))
        #expect(!RightPaneTabBarLayout.iconOnly.showsCount(for: .changes, activeTab: .changes))
        #expect(!RightPaneTabBarLayout.iconOnly.showsCount(for: .run, activeTab: .run))
    }

    @Test func accessibilityLabelIncludesCountOnlyWhenTheCountIsVisible() {
        #expect(RightPaneTabBarLayout.regular.accessibilityLabel("Changes", count: 3, for: .changes, activeTab: .files) == "Changes, 3")
        #expect(RightPaneTabBarLayout.compact.accessibilityLabel("Changes", count: 3, for: .changes, activeTab: .changes) == "Changes, 3")
        #expect(RightPaneTabBarLayout.compact.accessibilityLabel("Changes", count: 3, for: .changes, activeTab: .files) == "Changes")
        #expect(RightPaneTabBarLayout.iconOnly.accessibilityLabel("Changes", count: 3, for: .changes, activeTab: .changes) == "Changes")
        #expect(RightPaneTabBarLayout.compact.accessibilityLabel("Files", count: nil, for: .files, activeTab: .files) == "Files")
    }
}
