import Foundation
import Testing
@testable import Alas

struct DiffInlineCommentModelTests {
    // MARK: - Helpers

    private func makeNewLine(newLine: Int, rowIndex: Int = 0) -> DiffDisplayLine {
        DiffDisplayLine(
            id: "line:new:\(rowIndex)",
            anchor: DiffLineAnchor(
                filePath: "Sources/App.swift",
                hunkIndex: 0,
                rowIndex: rowIndex,
                side: .new,
                oldLine: nil,
                newLine: newLine
            ),
            text: "let x = \(newLine)",
            lineNumber: newLine,
            kind: .add,
            inlineSpans: [],
            noTrailingNewline: false
        )
    }

    private func makeOldLine(oldLine: Int, rowIndex: Int = 0) -> DiffDisplayLine {
        DiffDisplayLine(
            id: "line:old:\(rowIndex)",
            anchor: DiffLineAnchor(
                filePath: "Sources/App.swift",
                hunkIndex: 0,
                rowIndex: rowIndex,
                side: .old,
                oldLine: oldLine,
                newLine: nil
            ),
            text: "let y = \(oldLine)",
            lineNumber: oldLine,
            kind: .delete,
            inlineSpans: [],
            noTrailingNewline: false
        )
    }

    private func makeRow(id: String, new: DiffDisplayLine?, old: DiffDisplayLine? = nil) -> DiffDisplayRow {
        DiffDisplayRow(
            id: id,
            kind: new != nil ? .add : .delete,
            old: old,
            new: new,
            collapsedLineCount: 0
        )
    }

    private func makeThread(id: String, newLine: Int) -> DiffInlineCommentThread {
        DiffInlineCommentThread(
            id: id,
            filePath: "Sources/App.swift",
            newLine: newLine,
            isResolved: false,
            isOutdated: false,
            comments: [
                DiffInlineComment(id: "\(id)-c1", author: "alice", body: "Nice work"),
            ]
        )
    }

    // MARK: - Tests

    @Test func emptyThreadsReturnsSingleSegment() {
        let rows = [
            makeRow(id: "r0", new: makeNewLine(newLine: 1, rowIndex: 0)),
            makeRow(id: "r1", new: makeNewLine(newLine: 2, rowIndex: 1)),
            makeRow(id: "r2", new: makeNewLine(newLine: 3, rowIndex: 2)),
        ]

        let blocks = DiffInlineCommentLayout.blocks(visibleRows: rows, threads: [])

        #expect(blocks.count == 1)
        if case .rows(let seg) = blocks[0] {
            #expect(seg.rows.count == 3)
            #expect(seg.id == "seg-0")
        } else {
            Issue.record("Expected .rows block")
        }
    }

    @Test func threadAnchorsAfterItsRow() {
        let rows = [
            makeRow(id: "r0", new: makeNewLine(newLine: 10, rowIndex: 0)),
            makeRow(id: "r1", new: makeNewLine(newLine: 20, rowIndex: 1)),
            makeRow(id: "r2", new: makeNewLine(newLine: 30, rowIndex: 2)),
        ]
        let thread = makeThread(id: "t1", newLine: 20)

        let blocks = DiffInlineCommentLayout.blocks(visibleRows: rows, threads: [thread])

        // Expected: seg[r0, r1], thread, seg[r2]
        #expect(blocks.count == 3)
        if case .rows(let seg) = blocks[0] {
            #expect(seg.rows.count == 2)
            #expect(seg.rows[0].id == "r0")
            #expect(seg.rows[1].id == "r1")
        } else {
            Issue.record("Block 0 should be .rows")
        }
        if case .thread(let t) = blocks[1] {
            #expect(t.id == "t1")
        } else {
            Issue.record("Block 1 should be .thread")
        }
        if case .rows(let seg) = blocks[2] {
            #expect(seg.rows.count == 1)
            #expect(seg.rows[0].id == "r2")
        } else {
            Issue.record("Block 2 should be .rows")
        }
    }

    @Test func multipleThreadsOnSameLine() {
        let rows = [
            makeRow(id: "r0", new: makeNewLine(newLine: 5, rowIndex: 0)),
            makeRow(id: "r1", new: makeNewLine(newLine: 10, rowIndex: 1)),
        ]
        let threadA = makeThread(id: "tA", newLine: 10)
        let threadB = makeThread(id: "tB", newLine: 10)

        let blocks = DiffInlineCommentLayout.blocks(visibleRows: rows, threads: [threadA, threadB])

        // Expected: seg[r0, r1], threadA, threadB — no trailing segment since rows[1] is last row
        #expect(blocks.count == 3)
        if case .rows(let seg) = blocks[0] {
            #expect(seg.rows.count == 2)
        } else {
            Issue.record("Block 0 should be .rows")
        }
        if case .thread(let t) = blocks[1] {
            #expect(t.id == "tA")
        } else {
            Issue.record("Block 1 should be .thread(tA)")
        }
        if case .thread(let t) = blocks[2] {
            #expect(t.id == "tB")
        } else {
            Issue.record("Block 2 should be .thread(tB)")
        }
    }

    @Test func threadWithUnmatchedLineIsDropped() {
        let rows = [
            makeRow(id: "r0", new: makeNewLine(newLine: 1, rowIndex: 0)),
            makeRow(id: "r1", new: makeNewLine(newLine: 2, rowIndex: 1)),
        ]
        let thread = makeThread(id: "tX", newLine: 99)

        let blocks = DiffInlineCommentLayout.blocks(visibleRows: rows, threads: [thread])

        #expect(blocks.count == 1)
        if case .rows(let seg) = blocks[0] {
            #expect(seg.rows.count == 2)
        } else {
            Issue.record("Expected single .rows block")
        }
    }

    @Test func deletedRowsHaveNoNewSideAnchor() {
        // A delete-only row (new == nil) should never match any thread's newLine.
        let rows = [
            makeRow(id: "r0", new: nil, old: makeOldLine(oldLine: 5, rowIndex: 0)),
            makeRow(id: "r1", new: makeNewLine(newLine: 6, rowIndex: 1)),
        ]
        // Thread pointing at newLine 5 — no row has new.anchor.newLine == 5 (r0 has new == nil)
        let thread = makeThread(id: "tDel", newLine: 5)

        let blocks = DiffInlineCommentLayout.blocks(visibleRows: rows, threads: [thread])

        // Thread should be dropped; we get a single segment with both rows
        #expect(blocks.count == 1)
        if case .rows(let seg) = blocks[0] {
            #expect(seg.rows.count == 2)
        } else {
            Issue.record("Expected single .rows block")
        }
    }

    @Test func threadOnLastRow() {
        let rows = [
            makeRow(id: "r0", new: makeNewLine(newLine: 1, rowIndex: 0)),
            makeRow(id: "r1", new: makeNewLine(newLine: 2, rowIndex: 1)),
        ]
        let thread = makeThread(id: "tLast", newLine: 2)

        let blocks = DiffInlineCommentLayout.blocks(visibleRows: rows, threads: [thread])

        // Expected: seg[r0, r1], thread — no trailing empty segment
        #expect(blocks.count == 2)
        if case .rows(let seg) = blocks[0] {
            #expect(seg.rows.count == 2)
        } else {
            Issue.record("Block 0 should be .rows")
        }
        if case .thread(let t) = blocks[1] {
            #expect(t.id == "tLast")
        } else {
            Issue.record("Block 1 should be .thread")
        }
    }

    @Test func multipleThreadsOnDifferentRows() {
        let rows = [
            makeRow(id: "r0", new: makeNewLine(newLine: 1, rowIndex: 0)),
            makeRow(id: "r1", new: makeNewLine(newLine: 2, rowIndex: 1)),
            makeRow(id: "r2", new: makeNewLine(newLine: 3, rowIndex: 2)),
            makeRow(id: "r3", new: makeNewLine(newLine: 4, rowIndex: 3)),
        ]
        let thread1 = makeThread(id: "t1", newLine: 2) // after row index 1
        let thread2 = makeThread(id: "t2", newLine: 4) // after row index 3

        let blocks = DiffInlineCommentLayout.blocks(visibleRows: rows, threads: [thread1, thread2])

        // Expected: seg[r0,r1], t1, seg[r2,r3], t2
        #expect(blocks.count == 4)
        if case .rows(let seg) = blocks[0] {
            #expect(seg.rows.count == 2)
            #expect(seg.rows[0].id == "r0")
            #expect(seg.rows[1].id == "r1")
        } else {
            Issue.record("Block 0 should be .rows")
        }
        if case .thread(let t) = blocks[1] {
            #expect(t.id == "t1")
        } else {
            Issue.record("Block 1 should be .thread(t1)")
        }
        if case .rows(let seg) = blocks[2] {
            #expect(seg.rows.count == 2)
            #expect(seg.rows[0].id == "r2")
            #expect(seg.rows[1].id == "r3")
        } else {
            Issue.record("Block 2 should be .rows")
        }
        if case .thread(let t) = blocks[3] {
            #expect(t.id == "t2")
        } else {
            Issue.record("Block 3 should be .thread(t2)")
        }
    }

    @Test func emptyVisibleRowsReturnsEmpty() {
        let blocks = DiffInlineCommentLayout.blocks(visibleRows: [], threads: [])
        #expect(blocks.isEmpty)
    }

    @Test func annotationAndThreadOnSameLineEmitsBothBlocks() {
        let rows = [
            makeRow(id: "r0", new: makeNewLine(newLine: 1, rowIndex: 0)),
            makeRow(id: "r1", new: makeNewLine(newLine: 5, rowIndex: 1)),
            makeRow(id: "r2", new: makeNewLine(newLine: 9, rowIndex: 2)),
        ]
        let thread = makeThread(id: "t1", newLine: 5)
        let annotation = DiffInlineAnnotation(
            id: "a1",
            checkName: "SwiftLint",
            newLine: 5,
            level: .failure,
            message: "Line too long",
            rawDetails: nil
        )

        let blocks = DiffInlineCommentLayout.blocks(
            visibleRows: rows,
            threads: [thread],
            annotations: [annotation]
        )

        // Expected: seg[r0, r1], thread(t1), annotation(a1), seg[r2]
        #expect(blocks.count == 4)
        if case .rows(let seg) = blocks[0] {
            #expect(seg.rows.count == 2)
        } else {
            Issue.record("Block 0 should be .rows")
        }
        if case .thread(let t) = blocks[1] {
            #expect(t.id == "t1")
        } else {
            Issue.record("Block 1 should be .thread")
        }
        if case .annotation(let a) = blocks[2] {
            #expect(a.id == "a1")
        } else {
            Issue.record("Block 2 should be .annotation")
        }
        if case .rows(let seg) = blocks[3] {
            #expect(seg.rows.count == 1)
            #expect(seg.rows[0].id == "r2")
        } else {
            Issue.record("Block 3 should be .rows")
        }
    }

    @Test func annotationWithUnmatchedLineIsDropped() {
        let rows = [
            makeRow(id: "r0", new: makeNewLine(newLine: 1, rowIndex: 0)),
            makeRow(id: "r1", new: makeNewLine(newLine: 2, rowIndex: 1)),
        ]
        let annotation = DiffInlineAnnotation(
            id: "aX",
            checkName: "CI",
            newLine: 99,
            level: .warning,
            message: "Some warning",
            rawDetails: nil
        )

        let blocks = DiffInlineCommentLayout.blocks(
            visibleRows: rows,
            threads: [],
            annotations: [annotation]
        )

        #expect(blocks.count == 1)
        if case .rows(let seg) = blocks[0] {
            #expect(seg.rows.count == 2)
        } else {
            Issue.record("Expected single .rows block")
        }
    }
}
