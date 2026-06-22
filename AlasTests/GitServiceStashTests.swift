import Foundation
import Testing
@testable import Alas

@Suite(.serialized)
struct GitServiceStashTests {
    @Test func parseStashListPreservesRefSubjectRelativeTimeAndSha() {
        let output = """
        stash@{0}\u{1f}WIP on main: abc123 update parser\u{1f}2 hours ago\u{1f}1111111111111111111111111111111111111111
        stash@{1}\u{1f}custom message\u{1f}3 days ago\u{1f}2222222222222222222222222222222222222222

        """

        let stashes = GitService.parseStashList(output)

        #expect(stashes == [
            GitStash(
                ref: "stash@{0}",
                subject: "WIP on main: abc123 update parser",
                relativeTime: "2 hours ago",
                sha: "1111111111111111111111111111111111111111"
            ),
            GitStash(
                ref: "stash@{1}",
                subject: "custom message",
                relativeTime: "3 days ago",
                sha: "2222222222222222222222222222222222222222"
            ),
        ])
    }

    @Test func parseStashFilesMergesNumstatAndNameStatus() {
        let numstat = """
        12\t3\tSources/App.swift
        -\t-\tAssets/icon.png
        4\t0\tSources/New.swift

        """
        let nameStatus = """
        M\tSources/App.swift
        M\tAssets/icon.png
        A\tSources/New.swift

        """

        let files = GitService.parseStashFiles(numstat: numstat, nameStatus: nameStatus)

        #expect(files == [
            GitStashFile(path: "Sources/App.swift", status: "M", add: 12, del: 3),
            GitStashFile(path: "Assets/icon.png", status: "M", add: 0, del: 0),
            GitStashFile(path: "Sources/New.swift", status: "A", add: 4, del: 0),
        ])
    }

    @Test func parseStashFilesHandlesRenamesUsingNewPath() {
        let numstat = "1\t2\tSources/Old.swift => Sources/New.swift\n"
        let nameStatus = "R100\tSources/Old.swift\tSources/New.swift\n"

        let files = GitService.parseStashFiles(numstat: numstat, nameStatus: nameStatus)

        #expect(files == [
            GitStashFile(path: "Sources/New.swift", status: "R", add: 1, del: 2),
        ])
    }

    @Test func parseStashFilesHandlesBraceRenameNumstatUsingNewPath() {
        let numstat = "1\t2\tSources/{Old.swift => New.swift}\n"
        let nameStatus = "R100\tSources/Old.swift\tSources/New.swift\n"

        let files = GitService.parseStashFiles(numstat: numstat, nameStatus: nameStatus)

        #expect(files == [
            GitStashFile(path: "Sources/New.swift", status: "R", add: 1, del: 2),
        ])
    }
}
