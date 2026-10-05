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

    @Test("tray starts collapsed above three tasks")
    func defaultExpansion() {
        #expect(ACPBackgroundTaskPresentation.defaultExpanded(taskCount: 3))
        #expect(!ACPBackgroundTaskPresentation.defaultExpanded(taskCount: 4))
    }

    @Test("tray height follows task count, errors, expansion and the scroll cap", arguments: [
        (0, 0, nil, 0.0), (1, 0, nil, 58.0), (3, 0, nil, 110.0), (4, 0, nil, 32.0),
        (4, 0, true, 136.0), (2, 0, false, 32.0), (1, 1, nil, 90.0), (10, 0, true, 188.0),
    ] as [(Int, Int, Bool?, CGFloat)])
    func trayHeight(count: Int, errorCount: Int, override: Bool?, expected: CGFloat) {
        let tasks = (0..<count).map { index -> ACPBackgroundTask in
            var task = ACPBackgroundTask(ownerSessionId: "s", asyncTaskId: "t\(index)", name: "sleep 1")
            if index < errorCount { task.stopError = "stop failed" }
            return task
        }
        #expect(ACPBackgroundTaskPresentation.trayHeight(tasks: tasks, expandedOverride: override) == expected)
    }

    @Test("elapsed time formats by magnitude", arguments: [
        (-5.0, "0s"), (48.0, "48s"), (134.0, "2m 14s"), (3723.0, "1h 02m"),
    ])
    func elapsedText(interval: TimeInterval, expected: String) {
        #expect(ACPBackgroundTaskPresentation.elapsedText(interval) == expected)
    }
}
