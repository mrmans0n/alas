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

        #expect(FilesTabView.showsInlineLoadingIndicator(
            for: loadingDirectory,
            open: true,
            canExpand: true
        ))
        #expect(!FilesTabView.showsInlineLoadingIndicator(
            for: loadingDirectory,
            open: false,
            canExpand: true
        ))
        #expect(!FilesTabView.showsInlineLoadingIndicator(
            for: loadingDirectory,
            open: true,
            canExpand: false
        ))
        #expect(!FilesTabView.showsInlineLoadingIndicator(
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

            #expect(!FilesTabView.showsInlineLoadingIndicator(
                for: node,
                open: true,
                canExpand: true
            ))
        }
    }
}
