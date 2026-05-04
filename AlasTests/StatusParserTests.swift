import Testing
import Foundation
@testable import Alas

struct StatusParserTests {
    @Test func parsesModifiedFile() throws {
        let raw = "1 .M N... 100644 100644 100644 deadbeef deadbeef src/foo.rs"
        let entries = try StatusParser.parse(raw + "\u{0}")
        #expect(entries.count == 1)
        #expect(entries[0].path == "src/foo.rs")
        #expect(entries[0].status == "M")
    }

    @Test func parsesAddedAndDeleted() throws {
        let raw = "1 A. N... 000000 100644 100644 0 d new.rs\u{0}1 D. N... 100644 000000 000000 d 0 old.rs\u{0}"
        let entries = try StatusParser.parse(raw)
        #expect(entries.contains(where: { $0.status == "A" && $0.path == "new.rs" }))
        #expect(entries.contains(where: { $0.status == "D" && $0.path == "old.rs" }))
    }

    @Test func parsesRename() throws {
        let raw = "2 R. N... 100644 100644 100644 a a R100 docs/SPLIT.md\u{0}docs/PANES.md\u{0}"
        let entries = try StatusParser.parse(raw)
        #expect(entries.count == 1)
        #expect(entries[0].status == "R")
        #expect(entries[0].path == "docs/SPLIT.md")
        #expect(entries[0].renameFrom == "docs/PANES.md")
    }

    @Test func parsesUntracked() throws {
        let raw = "? scratch.txt\u{0}"
        let entries = try StatusParser.parse(raw)
        #expect(entries[0].status == "A")
        #expect(entries[0].path == "scratch.txt")
    }
}
