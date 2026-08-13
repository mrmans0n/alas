import Foundation
import Testing
@testable import Alas

struct RunScriptFailureTests {
    private func failure(_ index: Int, worktreeID: String = "wt") -> RunScriptFailure {
        RunScriptFailure(
            id: "failure-\(index)", runID: "run-\(index)",
            scriptKey: "repo:script-\(index).sh", scriptName: "Script \(index)",
            worktreeID: worktreeID, branch: "main", exitCode: Int32(index),
            completedAt: Date(timeIntervalSince1970: TimeInterval(index)),
            capturedOutput: .available(text: "output \(index)", truncated: false)
        )
    }

    @Test func queueKeepsThreeNewestPerWorktree() {
        var queue = RunScriptFailureQueue()
        for index in 1...4 { queue.append(failure(index)) }
        #expect(queue.failures(for: "wt").map(\.id) == ["failure-4", "failure-3", "failure-2"])
    }

    @Test func queueEvictsByCompletionTime() {
        var queue = RunScriptFailureQueue()
        for index in 2...4 { queue.append(failure(index)) }
        queue.append(failure(1))
        #expect(queue.failures(for: "wt").map(\.id) == ["failure-4", "failure-3", "failure-2"])
    }

    @Test func dismissAndPurgeAreWorktreeScoped() {
        var queue = RunScriptFailureQueue()
        queue.append(failure(1, worktreeID: "a"))
        queue.append(failure(2, worktreeID: "b"))
        queue.dismiss(id: "failure-1", worktreeID: "a")
        #expect(queue.failures(for: "a").isEmpty)
        #expect(queue.failures(for: "b").map(\.id) == ["failure-2"])
        queue.purge(worktreeID: "b")
        #expect(queue.failures(for: "b").isEmpty)
    }

    @Test func tailStripsControlsAndResolvesCarriageReturns() {
        let data = Data("old\r\u{1B}[31mnew\u{1B}[0m\u{07}\n".utf8)
        let result = ANSIPlainTextSnapshot.tail(from: data, byteLimit: 1_024)
        #expect(result.text == "new\n")
        #expect(!result.truncated)
    }

    @Test func tailNormalizesCRLFBeforeCarriageReturnHandling() {
        let data = Data("error\r\nprogress\rdone\n".utf8)
        let result = ANSIPlainTextSnapshot.tail(from: data, byteLimit: 1_024, normalizesCRLF: true)
        #expect(result.text == "error\ndone\n")
    }

    @Test func tailDoesNotSplitUnicode() {
        let data = Data((String(repeating: "x", count: 20) + "🎉end").utf8)
        let result = ANSIPlainTextSnapshot.tail(from: data, byteLimit: 7)
        #expect(result.text == "🎉end")
        #expect(result.truncated)
        #expect(!result.text.contains("�"))
    }

    @Test func tailSanitizesControlsFromRetainedLookbehindBeforeTrimming() {
        let data = Data(("\u{1B}]8;;" + String(repeating: "secret", count: 500) + "\u{07}visible").utf8)
        let result = ANSIPlainTextSnapshot.tail(from: data, byteLimit: 16)
        #expect(result.text == "visible")
        #expect(result.truncated)
        #expect(!result.text.contains("secret"))
    }
}
