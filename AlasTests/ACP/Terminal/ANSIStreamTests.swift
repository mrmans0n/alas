import Foundation
import SwiftUI
import Testing
@testable import Alas

@Suite("ANSIStream")
struct ANSIStreamTests {
    @Test("plain text passes through with default attributes")
    func plainText() {
        var s = ANSIStream()
        let runs = s.feed(Data("hello world".utf8))
        #expect(runs.count == 1)
        #expect(runs[0].text == "hello world")
        #expect(runs[0].attributes == .default)
    }

    @Test("SGR red foreground produces a red run")
    func redForeground() {
        var s = ANSIStream()
        let runs = s.feed(Data("\u{1B}[31mred\u{1B}[0m".utf8))
        let red = runs.first { $0.text == "red" }
        #expect(red?.attributes.foreground == .red)
    }

    @Test("partial escape split across feeds produces correct output")
    func partialEscape() {
        var s = ANSIStream()
        var runs = s.feed(Data("\u{1B}[3".utf8))
        runs += s.feed(Data("1mhi\u{1B}[0m".utf8))
        #expect(runs.contains { $0.text == "hi" && $0.attributes.foreground == .red })
    }

    @Test("non-SGR CSI is consumed silently")
    func cursorMoveStripped() {
        var s = ANSIStream()
        let runs = s.feed(Data("a\u{1B}[2Jb".utf8))
        let text = runs.map(\.text).joined()
        #expect(text == "ab")
    }

    @Test("OSC sequence is consumed silently")
    func oscStripped() {
        var s = ANSIStream()
        let runs = s.feed(Data("\u{1B}]0;title\u{07}body".utf8))
        let text = runs.map(\.text).joined()
        #expect(text == "body")
    }

    @Test("OSC sequence terminated by ESC \\ is consumed silently")
    func oscSTStripped() {
        var s = ANSIStream()
        let runs = s.feed(Data("\u{1B}]0;title\u{1B}\\body".utf8))
        let text = runs.map(\.text).joined()
        #expect(text == "body")
    }

    @Test("CR causes line restart")
    func carriageReturnRestartsLine() {
        var s = ANSIStream()
        let runs = s.feed(Data("downloading 10%\rdownloading 50%\rdownloading 99%\n".utf8))
        let text = runs.map(\.text).joined()
        #expect(text == "downloading 99%\n")
    }

    @Test("256-color SGR uses xterm 256 palette")
    func xterm256() {
        var s = ANSIStream()
        let runs = s.feed(Data("\u{1B}[38;5;196mX\u{1B}[0m".utf8))
        let x = runs.first { $0.text == "X" }
        // 196 is bright red in the xterm-256 palette
        #expect(x?.attributes.foreground != nil)
        #expect(x?.attributes.foreground != .default)
    }

    @Test("truecolor SGR carries exact RGB")
    func truecolor() {
        var s = ANSIStream()
        let runs = s.feed(Data("\u{1B}[38;2;10;20;30mY\u{1B}[0m".utf8))
        let y = runs.first { $0.text == "Y" }
        #expect(y?.attributes.foreground == .rgb(red: 10, green: 20, blue: 30))
    }

    @Test("BEL and other C0 controls are dropped")
    func c0Stripped() {
        var s = ANSIStream()
        let runs = s.feed(Data("a\u{07}b".utf8))
        let text = runs.map(\.text).joined()
        #expect(text == "ab")
    }

    @Test("multibyte UTF-8 decodes to the correct scalar")
    func multibyteUTF8() {
        var s = ANSIStream()
        let runs = s.feed(Data("café 日本語 🎉".utf8))
        let text = runs.map(\.text).joined()
        #expect(text == "café 日本語 🎉")
    }

    @Test("UTF-8 codepoint split across feeds reassembles")
    func splitMultibyteUTF8() {
        var s = ANSIStream()
        // 🎉 is F0 9F 8E 89; split at the 3-byte mark.
            let full = Array("🎉".utf8)
        var runs = s.feed(Data(full.prefix(3)))
        runs += s.feed(Data(full.suffix(from: 3)))
        let text = runs.map(\.text).joined()
        #expect(text == "🎉")
    }

    @Test("CR truncation still works after a prior feed emitted an LF")
    func crAcrossFeedsAfterLF() {
        var s = ANSIStream()
        _ = s.feed(Data("ok\n".utf8))
        // Second feed starts a fresh logical line; emittedLineStart must
        // reset to 0 so CR can still truncate the colored prefix.
        let runs = s.feed(Data("\u{1B}[31m10\u{1B}[33m%\r\u{1B}[32m20%".utf8))
        let text = runs.map(\.text).joined()
        #expect(text == "20%")
        #expect(runs.allSatisfy { $0.attributes.foreground == .green })
    }

    @Test("CR drops previously emitted colored runs on the same line")
    func crDropsColoredPrefix() {
        var s = ANSIStream()
        // Red "10%" is flushed when the second ESC arrives, then CR
        // should discard it before the new green "20%" is emitted.
        let runs = s.feed(Data("\u{1B}[31m10\u{1B}[33m%\r\u{1B}[32m20%".utf8))
        let text = runs.map(\.text).joined()
        #expect(text == "20%")
        #expect(runs.allSatisfy { $0.attributes.foreground == .green })
    }

    @Test("multibyte UTF-8 colored by SGR carries the right text")
    func multibyteWithSGR() {
        var s = ANSIStream()
        let runs = s.feed(Data("\u{1B}[31mé\u{1B}[0m".utf8))
        let e = runs.first { $0.text == "é" }
        #expect(e?.attributes.foreground == .red)
    }

    @Test("incremental tail preserves parser state across chunks")
    func incrementalTailPreservesState() {
        var tail = ANSITailBuffer(byteLimit: 1024)
        tail.feed(Data("\u{1B}[3".utf8))
        tail.feed(Data("1mred".utf8))

        #expect(tail.runs.map(\.text).joined() == "red")
        #expect(tail.runs.allSatisfy { $0.attributes.foreground == .red })
    }

    @Test("incremental tail applies carriage-return redraw across chunks")
    func incrementalTailCarriageReturnAcrossChunks() {
        var tail = ANSITailBuffer(byteLimit: 1024)
        tail.feed(Data("complete\nprogress 10%".utf8))
        tail.feed(Data("\rprogress 90%".utf8))

        #expect(tail.runs.map(\.text).joined() == "complete\nprogress 90%")
    }

    @Test("incremental tail stays within its byte limit")
    func incrementalTailIsBounded() {
        var tail = ANSITailBuffer(byteLimit: 8)
        tail.feed(Data("1234\n".utf8))
        tail.feed(Data("567890".utf8))

        #expect(tail.retainedByteCount <= 8)
        #expect(tail.runs.map(\.text).joined() == "4\n567890")
    }

    @Test("incremental tail truncation keeps a UTF-8 boundary")
    func incrementalTailUTF8Boundary() {
        var tail = ANSITailBuffer(byteLimit: 9)
        tail.feed(Data("x🎉🎉🎉".utf8))
        let text = tail.runs.map(\.text).joined()

        #expect(tail.retainedByteCount <= 9)
        #expect(text == "🎉🎉")
        #expect(!text.contains("\u{FFFD}"))
    }
}
