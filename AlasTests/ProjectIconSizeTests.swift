import Testing
@testable import Alas

@MainActor
struct ProjectIconSizeTests {
    @Test func repoHeaderMatchesE1Tile() {
        #expect(ProjectIconView.Size.repoHeader.dimension == 19)
        #expect(ProjectIconView.Size.repoHeader.cornerRadius == 5)
        #expect(ProjectIconView.Size.repoHeader.fontSize == 9.5)
    }

    @Test func sidebarSizeIsUnchanged() {
        // .sidebar is shared with RepoSelectorRowView, NewProjectDialog,
        // WorkspaceDialogs, RootView and WorkspaceSidebarTree. The E1 repo
        // header gets its own case precisely so those keep their sizing.
        #expect(ProjectIconView.Size.sidebar.dimension == 16)
        #expect(ProjectIconView.Size.sidebar.cornerRadius == 4)
    }
}
