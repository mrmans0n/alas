import Testing
import Foundation
@testable import Alas

struct StatusParserTests {
    @Test func parsesUnstagedModifiedFile() throws {
        let raw = "1 .M N... 100644 100644 100644 deadbeef deadbeef src/foo.rs"
        let entries = try StatusParser.parse(raw + "\u{0}")
        let entry = try #require(entries.first)
        #expect(entry.path == "src/foo.rs")
        #expect(entry.status == "M")
        #expect(entry.stage == .unstaged)
    }

    @Test func parsesStagedModifiedFile() throws {
        let raw = "1 M. N... 100644 100644 100644 deadbeef deadbeef src/foo.rs\u{0}"
        let entries = try StatusParser.parse(raw)
        let entry = try #require(entries.first)
        #expect(entry.path == "src/foo.rs")
        #expect(entry.status == "M")
        #expect(entry.stage == .staged)
    }

    @Test func parsesPartiallyStagedModifiedFile() throws {
        let raw = "1 MM N... 100644 100644 100644 deadbeef deadbeef src/foo.rs\u{0}"
        let entries = try StatusParser.parse(raw)
        #expect(entries.count == 2)
        let staged = entries.first(where: { $0.stage == .staged })
        let unstaged = entries.first(where: { $0.stage == .unstaged })
        #expect(staged != nil)
        #expect(unstaged != nil)
        #expect(staged?.path == "src/foo.rs")
        #expect(staged?.status == "M")
        #expect(unstaged?.path == "src/foo.rs")
        #expect(unstaged?.status == "M")
        let ids = Set(entries.map(\.id))
        #expect(ids.count == 2)
    }

    @Test func parsesAddedAndDeleted() throws {
        let raw = "1 A. N... 000000 100644 100644 0 d new.rs\u{0}1 .D N... 100644 000000 000000 d 0 old.rs\u{0}"
        let entries = try StatusParser.parse(raw)
        let added = entries.first(where: { $0.path == "new.rs" })
        let deleted = entries.first(where: { $0.path == "old.rs" })
        #expect(added?.status == "A")
        #expect(added?.stage == .staged)
        #expect(deleted?.status == "D")
        #expect(deleted?.stage == .unstaged)
    }

    @Test func parsesRename() throws {
        let raw = "2 R. N... 100644 100644 100644 a a R100 docs/SPLIT.md\u{0}docs/PANES.md\u{0}"
        let entries = try StatusParser.parse(raw)
        let entry = try #require(entries.first)
        #expect(entry.status == "R")
        #expect(entry.stage == .staged)
        #expect(entry.path == "docs/SPLIT.md")
        #expect(entry.renameFrom == "docs/PANES.md")
    }

    @Test func parsesRenameWithUnstagedModification() throws {
        let raw = "2 RM N... 100644 100644 100644 a a R100 docs/SPLIT.md\u{0}docs/PANES.md\u{0}"
        let entries = try StatusParser.parse(raw)
        #expect(entries.count == 2)
        let staged = entries.first(where: { $0.stage == .staged })
        let unstaged = entries.first(where: { $0.stage == .unstaged })
        #expect(staged?.status == "R")
        #expect(staged?.path == "docs/SPLIT.md")
        #expect(staged?.renameFrom == "docs/PANES.md")
        #expect(unstaged?.status == "M")
        #expect(unstaged?.path == "docs/SPLIT.md")
        #expect(unstaged?.renameFrom == nil)
    }

    @Test func parsesUntracked() throws {
        let raw = "? scratch.txt\u{0}"
        let entries = try StatusParser.parse(raw)
        let entry = try #require(entries.first)
        #expect(entry.status == "A")
        #expect(entry.stage == .unstaged)
        #expect(entry.path == "scratch.txt")
    }
}