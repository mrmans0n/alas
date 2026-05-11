import Testing
import Foundation
@testable import Alas

struct StatusParserTests {
    @Test func parsesUnstagedModifiedFile() throws {
        let raw = "1 .M N... 100644 100644 100644 deadbeef deadbeef src/foo.rs"
        let entries = try StatusParser.parse(raw + "\u{0}")
        #expect(entries.count == 1)
        #expect(entries[0].path == "src/foo.rs")
        #expect(entries[0].status == "M")
        #expect(entries[0].stage == .unstaged)
    }

    @Test func parsesStagedModifiedFile() throws {
        let raw = "1 M. N... 100644 100644 100644 deadbeef deadbeef src/foo.rs\u{0}"
        let entries = try StatusParser.parse(raw)
        #expect(entries.count == 1)
        #expect(entries[0].path == "src/foo.rs")
        #expect(entries[0].status == "M")
        #expect(entries[0].stage == .staged)
    }

    @Test func parsesPartiallyStagedModifiedFile() throws {
        let raw = "1 MM N... 100644 100644 100644 deadbeef deadbeef src/foo.rs\u{0}"
        let entries = try StatusParser.parse(raw)
        #expect(entries.count == 2)
        #expect(entries.contains(where: { $0.path == "src/foo.rs" && $0.status == "M" && $0.stage == .staged }))
        #expect(entries.contains(where: { $0.path == "src/foo.rs" && $0.status == "M" && $0.stage == .unstaged }))
        #expect(Set(entries.map(\.id)).count == 2)
    }

    @Test func parsesAddedAndDeleted() throws {
        let raw = "1 A. N... 000000 100644 100644 0 d new.rs\u{0}1 .D N... 100644 000000 000000 d 0 old.rs\u{0}"
        let entries = try StatusParser.parse(raw)
        #expect(entries.contains(where: { $0.status == "A" && $0.path == "new.rs" && $0.stage == .staged }))
        #expect(entries.contains(where: { $0.status == "D" && $0.path == "old.rs" && $0.stage == .unstaged }))
    }

    @Test func parsesRename() throws {
        let raw = "2 R. N... 100644 100644 100644 a a R100 docs/SPLIT.md\u{0}docs/PANES.md\u{0}"
        let entries = try StatusParser.parse(raw)
        #expect(entries.count == 1)
        #expect(entries[0].status == "R")
        #expect(entries[0].stage == .staged)
        #expect(entries[0].path == "docs/SPLIT.md")
        #expect(entries[0].renameFrom == "docs/PANES.md")
    }

    @Test func parsesRenameWithUnstagedModification() throws {
        let raw = "2 RM N... 100644 100644 100644 a a R100 docs/SPLIT.md\u{0}docs/PANES.md\u{0}"
        let entries = try StatusParser.parse(raw)
        #expect(entries.count == 2)
        #expect(entries.contains(where: {
            $0.status == "R" && $0.stage == .staged && $0.path == "docs/SPLIT.md" && $0.renameFrom == "docs/PANES.md"
        }))
        #expect(entries.contains(where: {
            $0.status == "M" && $0.stage == .unstaged && $0.path == "docs/SPLIT.md" && $0.renameFrom == nil
        }))
    }

    @Test func parsesUntracked() throws {
        let raw = "? scratch.txt\u{0}"
        let entries = try StatusParser.parse(raw)
        #expect(entries[0].status == "A")
        #expect(entries[0].stage == .unstaged)
        #expect(entries[0].path == "scratch.txt")
    }
}
