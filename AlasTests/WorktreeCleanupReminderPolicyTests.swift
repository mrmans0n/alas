import Testing
@testable import Alas

struct WorktreeCleanupReminderPolicyTests {
    private static func ids(_ range: ClosedRange<Int>) -> Set<String> {
        Set(range.map { "wt-\($0)" })
    }

    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let ready: Set<String>
        let existing: Set<String>
        let dismissed: Set<String>
        let expected: Set<String>?
        var testDescription: String { name }
    }

    @Test(arguments: [
        Case(name: "below threshold", ready: ids(1...4), existing: ids(1...10), dismissed: [], expected: nil),
        Case(name: "at threshold", ready: ids(1...5), existing: ids(1...10), dismissed: [], expected: ids(1...5)),
        Case(name: "deleted worktrees stop counting", ready: ids(1...5), existing: ids(2...10), dismissed: [], expected: nil),
        Case(name: "dismissed set stays hidden", ready: ids(1...5), existing: ids(1...10), dismissed: ids(1...5), expected: nil),
        Case(name: "shrunk dismissed set stays hidden", ready: ids(1...5), existing: ids(1...10), dismissed: ids(1...6), expected: nil),
        Case(name: "newly ready worktree reopens", ready: ids(1...6), existing: ids(1...10), dismissed: ids(1...5), expected: ids(1...6)),
    ])
    func remindedWorktreeIds(_ testCase: Case) {
        #expect(WorktreeCleanupReminderPolicy.remindedWorktreeIds(
            ready: testCase.ready,
            existing: testCase.existing,
            dismissed: testCase.dismissed
        ) == testCase.expected)
    }
}
