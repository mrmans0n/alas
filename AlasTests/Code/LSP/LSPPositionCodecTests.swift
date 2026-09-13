import Testing
@testable import Alas

struct LSPPositionCodecTests {
    @Test func utf16PositionAfterEmoji() throws {
        #expect(try LSPPositionCodec.offset(
            LSPPosition(line: 0, character: 3), in: "a😀b") == 3)
    }

    @Test func supportsCRLFAndFinalEmptyLine() throws {
        #expect(try LSPPositionCodec.offset(
            LSPPosition(line: 1, character: 1), in: "one\r\ntwo\r\n") == 6)
        #expect(try LSPPositionCodec.offset(
            LSPPosition(line: 2, character: 0), in: "one\r\ntwo\r\n") == 10)
    }

    @Test func rejectsNegativeAndOutOfRangePositions() {
        #expect(throws: Error.self) {
            try LSPPositionCodec.offset(LSPPosition(line: -1, character: 0), in: "a")
        }
        #expect(throws: Error.self) {
            try LSPPositionCodec.offset(LSPPosition(line: 0, character: 2), in: "a")
        }
    }

    @Test func rejectsSurrogateSplittingPosition() {
        #expect(throws: Error.self) {
            try LSPPositionCodec.offset(LSPPosition(line: 0, character: 2), in: "a😀b")
        }
    }
}
