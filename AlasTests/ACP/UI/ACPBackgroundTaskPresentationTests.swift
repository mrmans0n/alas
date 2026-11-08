import Foundation
import Testing
@testable import Alas

@Suite("ACPBackgroundTaskPresentation")
struct ACPBackgroundTaskPresentationTests {
    typealias Parts = ACPBackgroundTaskPresentation.CommandParts

    @Test("splits shell commands into program and dimmed arguments", arguments: [
        ("gh run download 37245761108 --repo mrmans0n/alas --dir /tmp/x",
         Parts(head: "gh run download", arguments: "37245761108 --repo mrmans0n/alas --dir /tmp/x")),
        ("DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Alas.xcodeproj -scheme Alas",
         Parts(head: "xcodebuild", arguments: "-project Alas.xcodeproj -scheme Alas")),
        ("A=1 B=2 /usr/bin/env swift test --filter Foo",
         Parts(head: "env swift test", arguments: "--filter Foo")),
        ("sleep 30", Parts(head: "sleep", arguments: "30")),
        ("npm", Parts(head: "npm", arguments: "")),
    ])
    func splitsCommands(name: String, expected: Parts) {
        #expect(ACPBackgroundTaskPresentation.commandParts(name) == expected)
    }

    @Test("prose names are not treated as commands", arguments: [
        "Explore auth module", "Run the tests", "", "FOO=1",
    ])
    func proseIsNotACommand(name: String) {
        #expect(ACPBackgroundTaskPresentation.commandParts(name) == nil)
    }

    @Test("header animates only while collapsed and some task is running", arguments: [
        (false, false, ACPBackgroundTaskPresentation.HeaderIcon.spinner),
        (false, true, .paused),
        (true, false, .list),
        (true, true, .list),
    ])
    func headerIcon(expanded: Bool, allPaused: Bool, expected: ACPBackgroundTaskPresentation.HeaderIcon) {
        #expect(ACPBackgroundTaskPresentation.headerIcon(expanded: expanded, allPaused: allPaused) == expected)
    }

    @Test("elapsed time formats by magnitude", arguments: [
        (-5.0, "0s"), (48.0, "48s"), (134.0, "2m 14s"), (3723.0, "1h 02m"),
    ])
    func elapsedText(interval: TimeInterval, expected: String) {
        #expect(ACPBackgroundTaskPresentation.elapsedText(interval) == expected)
    }

    @Test("tooltip skips repeated or empty detail and preserves useful context", arguments: [
        ("make test", nil, "make test"),
        (nil, " make test\n", "make test"),
        ("make test", "Runs the unit tests", "make test\nRuns the unit tests"),
        ("3 tests failed", "make test", "make test\n3 tests failed"),
        (" ", nil, "make test"),
    ] as [(String?, String?, String)])
    func tooltip(summary: String?, description: String?, expected: String) {
        var task = ACPBackgroundTask(ownerSessionId: "s", asyncTaskId: "t", name: "make test")
        task.summary = summary
        task.description = description
        #expect(ACPBackgroundTaskPresentation.tooltip(task) == expected)
    }

    @Test("transcript detail prefers the summary and skips text that repeats the name", arguments: [
        (nil, "make test", nil),
        (nil, " make test\n", nil),
        ("3 tests failed", "make test", "3 tests failed"),
        ("make test", "Runs the unit tests", "Runs the unit tests"),
        ("", nil, nil),
    ] as [(String?, String?, String?)])
    func transcriptDetail(summary: String?, description: String?, expected: String?) {
        var task = ACPBackgroundTask(ownerSessionId: "s", asyncTaskId: "t", name: "make test")
        task.summary = summary
        task.description = description
        #expect(ACPBackgroundTaskPresentation.transcriptDetail(task) == expected)
    }
}
