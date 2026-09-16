import Foundation
import Testing
@testable import Alas

struct FilesTabLoadingIndicatorTests {
    @Test func inlineLoadingIndicatorOnlyShowsForOpenLoadingDirectories() {
        let loadingDirectory = FileTreeNode(
            name: "Sources",
            path: "Sources",
            kind: .dir,
            children: [],
            badge: nil,
            visibility: .tracked,
            childrenState: .loading
        )
        let loadingFile = FileTreeNode(
            name: "README.md",
            path: "README.md",
            kind: .file,
            children: nil,
            badge: nil,
            visibility: .tracked,
            childrenState: .loading
        )

        #expect(FileTreeListView.showsInlineLoadingIndicator(
            for: loadingDirectory,
            open: true,
            canExpand: true
        ))
        #expect(!FileTreeListView.showsInlineLoadingIndicator(
            for: loadingDirectory,
            open: false,
            canExpand: true
        ))
        #expect(!FileTreeListView.showsInlineLoadingIndicator(
            for: loadingDirectory,
            open: true,
            canExpand: false
        ))
        #expect(!FileTreeListView.showsInlineLoadingIndicator(
            for: loadingFile,
            open: true,
            canExpand: true
        ))
    }

    @Test func inlineLoadingIndicatorDoesNotShowForFinishedDirectoryStates() {
        for state in [DirectoryChildrenState.loaded, .notLoaded, .failed] {
            let node = FileTreeNode(
                name: "Sources",
                path: "Sources",
                kind: .dir,
                children: [],
                badge: nil,
                visibility: .tracked,
                childrenState: state
            )

            #expect(!FileTreeListView.showsInlineLoadingIndicator(
                for: node,
                open: true,
                canExpand: true
            ))
        }
    }

    @Test func loadTaskIDIncludesRefreshPublicationRevision() {
        let beforePublication = FileTreeListView.loadTaskID(
            fileTreeGeneration: 7,
            fileTreeRefreshRevision: 2,
            path: "build/cache",
            open: true,
            childrenState: .loaded
        )
        let afterPublication = FileTreeListView.loadTaskID(
            fileTreeGeneration: 7,
            fileTreeRefreshRevision: 3,
            path: "build/cache",
            open: true,
            childrenState: .loaded
        )

        #expect(beforePublication != afterPublication)
    }
}
