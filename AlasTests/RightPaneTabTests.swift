import Testing
@testable import Alas

struct RightPaneTabTests {
    @Test(arguments: [
        (false, [RightPaneTab.changes, .files, .agent, .run, .schedules]),
        (true, [RightPaneTab.files, .agent, .run, .schedules]),
    ])
    func availableTabsDropChangesOnlyForFolders(isFolder: Bool, expected: [RightPaneTab]) {
        #expect(RightPaneTab.available(isFolder: isFolder) == expected)
    }

    @Test(arguments: [(false, [RightPaneTab.changes, .files, .agent]), (true, [RightPaneTab.files, .agent])])
    func peerTabsDropChangesOnlyForFolders(isFolder: Bool, expected: [RightPaneTab]) {
        #expect(RightPaneTab.peerAvailable(isFolder: isFolder) == expected)
    }
}
