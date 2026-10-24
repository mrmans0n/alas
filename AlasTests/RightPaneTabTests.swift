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

    @Test(arguments: [
        (false, false, [RightPaneTab.changes, .files, .agent]),
        (true, false, [RightPaneTab.files, .agent]),
        (false, true, [RightPaneTab.changes, .files, .agent, .run]),
        (true, true, [RightPaneTab.files, .agent, .run]),
    ])
    func peerTabsOfferRunOnlyWhenTheHostServesScripts(isFolder: Bool, servesRuns: Bool, expected: [RightPaneTab]) {
        #expect(RightPaneTab.peerAvailable(isFolder: isFolder, servesRuns: servesRuns) == expected)
    }
}
