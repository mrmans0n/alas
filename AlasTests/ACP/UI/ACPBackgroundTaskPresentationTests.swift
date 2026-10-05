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

    @Test("tray height follows task count and expansion", arguments: [
        (0, nil, 0.0), (1, nil, 58.0), (3, nil, 110.0), (4, nil, 32.0), (4, true, 136.0), (2, false, 32.0),
    ] as [(Int, Bool?, CGFloat)])
    func trayHeight(count: Int, override: Bool?, expected: CGFloat) {
        #expect(ACPBackgroundTaskPresentation.trayHeight(taskCount: count, expandedOverride: override) == expected)
    }

    @Test("elapsed time formats by magnitude", arguments: [
        (-5.0, "0s"), (48.0, "48s"), (134.0, "2m 14s"), (3723.0, "1h 02m"),
    ])
    func elapsedText(interval: TimeInterval, expected: String) {
        #expect(ACPBackgroundTaskPresentation.elapsedText(interval) == expected)
    }
}
