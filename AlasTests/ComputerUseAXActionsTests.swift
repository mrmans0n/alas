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

    /// When the app moves the caret during chunked typing: right as a chunk goes in, or after
    /// that chunk's check and before the next one.
    enum CaretMove: CaseIterable { case withTheChunk, betweenChunks }

    /// Chunked typing stops where the caret moved instead of splitting the text across two places.
    @Test(arguments: CaretMove.allCases)
    func chunkedTypingStopsWhenTheCaretMoves(_ move: CaretMove) async throws {
        let field = FakeTextField(move: move)
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
}

/// A text field whose app moves the caret once the first chunk went in.
private final class FakeTextField: @unchecked Sendable {
    private let lock = NSLock()
    private let move: ComputerUseAXActionsTests.CaretMove
    private var length = 0
    private var location = 0
    private var rangeReads = 0
    private var written: [String] = []

    init(move: ComputerUseAXActionsTests.CaretMove) { self.move = move }

    var chunks: [String] { lock.withLock { written } }

    var target: ComputerUseAXActions.TextTarget {
        ComputerUseAXActions.TextTarget(
            canSetSelectedText: { true },
            characterCount: { self.lock.withLock { self.length } },
            selectedRange: {
                self.lock.withLock {
                    self.rangeReads += 1
                    // Read 1 is before the first chunk, 2 its check, 3 the next chunk's.
                    if self.move == .betweenChunks, self.rangeReads == 3 { self.location += 5 }
                    return CFRange(location: self.location, length: 0)
                }
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
                    if self.move == .withTheChunk, self.written.count == 1 { self.location += 5 }
                }
                return .success
            })
    }
}
