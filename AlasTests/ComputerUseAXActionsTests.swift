import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import Alas

struct ComputerUseAXActionsTests {
    /// A click by ref must show, whatever its button or count; typing by ref may target a field
    /// out of view, and scrolling is how one gets there.
    @Test(arguments: [
        (ComputerUseInput.click(.element(ComputerUseAXHandles(), 3), button: .left, count: 1), true),
        (.click(.element(ComputerUseAXHandles(), 3), button: .left, count: 2), true),
        (.click(.element(ComputerUseAXHandles(), 3), button: .right, count: 1), true),
        (.click(.point(.zero), button: .left, count: 1), false),
        (.type("a", target: .element(ComputerUseAXHandles(), 3), replace: false), false),
        (.scroll(.element(ComputerUseAXHandles(), 3), dx: 0, dy: 1), false),
        (.pointerClick(.element(ComputerUseAXHandles(), 3)), false),
    ])
    func clicksByRefAreRefusedWhenTheElementIsHidden(input: ComputerUseInput, checked: Bool) {
        #expect((input.refusedWhenHidden?.1 == 3) == checked)
    }

    /// Chunked typing stops where the app moved the caret after a chunk, instead of splitting the
    /// text across two places.
    @Test func chunkedTypingStopsWhenTheCaretMoves() async throws {
        let field = FakeTextField()
        let text = String(repeating: "a", count: 450)
        let app = ComputerUseAppIdentity(name: "Notes", bundleID: "com.apple.Notes", pid: 101)
        await #expect {
            try await ComputerUseAXActions.insert(text, into: field.target, app: app, interrupt: { nil })
        } throws: { error in
            guard case ComputerUseSystemError.actionFailed(let message) = error else { return false }
            return message == "Notes moved the text cursor; stopped after typing 200 of 450 characters."
        }
        #expect(field.chunks.count == 1)
    }

    /// A Chromium field that reports an insert over its selection as done and keeps its value:
    /// the insert is `Unsupported`, so the text is typed as events instead of reported as typed.
    @Test func anInsertThatLeftTheValueAsItWasIsUnsupported() async throws {
        let target = ComputerUseAXActions.TextTarget(
            canSetSelectedText: { true }, characterCount: { 7 }, selectedRange: { CFRange(location: 0, length: 7) },
            setSelectedRange: { _ in true }, setSelectedText: { _ in .success }, value: { "compose" })
        let app = ComputerUseAppIdentity(name: "Slack", bundleID: "com.tinyspeck.slackmacgap", pid: 101)
        await #expect(throws: ComputerUseAXActions.Unsupported.self) {
            try await ComputerUseAXActions.insert("kotlin", into: target, app: app, interrupt: { nil })
        }
    }

    /// A Chrome page's field is never written by AX, since a write the page did get and keys after
    /// it would type the text twice: it is typed as events, or refused where keys don't reach.
    @Test(arguments: [true, false])
    func aWebPageFieldIsNeverWrittenByAX(keysReach: Bool) async throws {
        let field = FakeTextField()
        var target = field.target
        target.inWebArea = true
        let app = ComputerUseAppIdentity(name: "Google Chrome", bundleID: "com.google.Chrome", pid: 101)
        await #expect {
            try await ComputerUseAXActions.insert("kotlin", into: target, app: app, keysReach: keysReach, interrupt: { nil })
        } throws: { error in
            if keysReach { return error is ComputerUseAXActions.Unsupported }
            guard case ComputerUseSystemError.actionFailed(let message) = error else { return false }
            return message == ComputerUseAXActions.offScreenTypeRefusal(app, .refNotTaken)
        }
        #expect(field.chunks.isEmpty)
    }
}

/// A text field whose app moves the caret once the first chunk went in.
private final class FakeTextField: @unchecked Sendable {
    private let lock = NSLock()
    private var length = 0
    private var location = 0
    private var written: [String] = []

    var chunks: [String] { lock.withLock { written } }

    var target: ComputerUseAXActions.TextTarget {
        ComputerUseAXActions.TextTarget(
            canSetSelectedText: { true },
            characterCount: { self.lock.withLock { self.length } },
            selectedRange: {
                self.lock.withLock { CFRange(location: self.location, length: 0) }
            },
            setSelectedRange: { range in
                self.lock.withLock { self.location = range.location }
                return true
            },
            setSelectedText: { chunk in
                self.lock.withLock {
                    self.written.append(chunk)
                    self.length += chunk.utf16.count
                    self.location += chunk.utf16.count
                    // The app moves the caret once the first chunk is in.
                    if self.written.count == 1 { self.location += 5 }
                }
                return .success
            })
    }
}
