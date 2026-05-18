import Testing
@testable import Alas

struct PendingDiscardTests {
    @Test func fileTitleAndMessage() {
        let p = PendingDiscard(target: .file(path: "src/foo/bar.swift"), paths: ["src/foo/bar.swift"])
        #expect(PendingDiscard.alertTitle(for: p) == "Discard changes to \u{201C}bar.swift\u{201D}?")
        #expect(PendingDiscard.alertMessage(for: p)
            == "This permanently removes your changes to this file. This cannot be undone.")
    }

    @Test func folderTitleAndMessageSingular() {
        let p = PendingDiscard(target: .folder(path: "src/foo", fileCount: 1), paths: ["src/foo/a.swift"])
        #expect(PendingDiscard.alertTitle(for: p) == "Discard changes under \u{201C}src/foo/\u{201D}?")
        #expect(PendingDiscard.alertMessage(for: p)
            == "This permanently removes changes to 1 file under this folder. This cannot be undone.")
    }

    @Test func folderTitleAndMessagePlural() {
        let p = PendingDiscard(target: .folder(path: "src", fileCount: 7), paths: [])
        #expect(PendingDiscard.alertMessage(for: p)
            == "This permanently removes changes to 7 files under this folder. This cannot be undone.")
    }

    @Test func allTitleAndMessage() {
        let p = PendingDiscard(target: .all(fileCount: 3), paths: [])
        #expect(PendingDiscard.alertTitle(for: p) == "Discard all working tree changes?")
        #expect(PendingDiscard.alertMessage(for: p)
            == "This permanently removes changes to 3 files (staged, unstaged, and untracked). This cannot be undone.")
    }

    @Test func allTitleAndMessageSingular() {
        let p = PendingDiscard(target: .all(fileCount: 1), paths: [])
        #expect(PendingDiscard.alertMessage(for: p)
            == "This permanently removes changes to 1 file (staged, unstaged, and untracked). This cannot be undone.")
    }
}
