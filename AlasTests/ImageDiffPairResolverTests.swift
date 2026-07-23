import Testing
@testable import Alas

struct ImageDiffPairResolverTests {
    // MARK: working-copy entries

    @Test func resolvesModifiedFromChangedFile() {
        let file = ChangedFile(
            path: "logo.png", status: "M", stage: .unstaged,
            add: 0, del: 0, renameFrom: nil
        )
        let r = ImageDiffPairResolver.resolveWorkingCopy(entry: file, fileExistsOnDisk: true, staged: false)
        #expect(r.kind == .modified)
        #expect(r.oldPath == nil)
    }

    @Test func resolvesAddedFromChangedFile() {
        let file = ChangedFile(
            path: "new.png", status: "A", stage: .unstaged,
            add: 0, del: 0, renameFrom: nil
        )
        let r = ImageDiffPairResolver.resolveWorkingCopy(entry: file, fileExistsOnDisk: true, staged: false)
        #expect(r.kind == .added)
        #expect(r.oldPath == nil)
    }

    @Test func resolvesDeletedFromChangedFile() {
        let file = ChangedFile(
            path: "gone.png", status: "D", stage: .unstaged,
            add: 0, del: 0, renameFrom: nil
        )
        let r = ImageDiffPairResolver.resolveWorkingCopy(entry: file, fileExistsOnDisk: false, staged: false)
        #expect(r.kind == .deleted)
        #expect(r.oldPath == nil)
    }

    @Test func resolvesRenamedFromChangedFile() {
        let file = ChangedFile(
            path: "new/path.png", status: "R", stage: .unstaged,
            add: 0, del: 0, renameFrom: "old/path.png"
        )
        let r = ImageDiffPairResolver.resolveWorkingCopy(entry: file, fileExistsOnDisk: true, staged: false)
        #expect(r.kind == .renamed)
        #expect(r.oldPath == "old/path.png")
    }

    @Test func resolvesUntrackedAsAdded() {
        // No entry at all in `git status` for tracked files — but for
        // untracked, the entry is still produced with status "?". Treat as
        // added regardless of letter when there is no rename and `before`
        // doesn't exist in HEAD (caller signals via nil entry).
        let r = ImageDiffPairResolver.resolveWorkingCopy(entry: nil, fileExistsOnDisk: true, staged: false)
        #expect(r.kind == .added)
    }

    // MARK: commit entries

    @Test func resolvesCommitFileAdded() {
        let f = CommitChangedFile(
            path: "new.png", originalPath: nil, status: "A", add: 0, del: 0
        )
        let r = ImageDiffPairResolver.resolveCommit(entry: f)
        #expect(r.kind == .added)
    }

    @Test func resolvesCommitFileDeleted() {
        let f = CommitChangedFile(
            path: "gone.png", originalPath: nil, status: "D", add: 0, del: 0
        )
        let r = ImageDiffPairResolver.resolveCommit(entry: f)
        #expect(r.kind == .deleted)
    }

    @Test func resolvesCommitFileRenamed() {
        let f = CommitChangedFile(
            path: "new/path.png", originalPath: "old/path.png", status: "R",
            add: 0, del: 0
        )
        let r = ImageDiffPairResolver.resolveCommit(entry: f)
        #expect(r.kind == .renamed)
        #expect(r.oldPath == "old/path.png")
    }

    @Test func resolvesCommitFileCopied() {
        let file = CommitChangedFile(
            path: "Assets/Copy.png",
            originalPath: "Assets/Original.png",
            status: "C",
            add: 0,
            del: 0
        )

        let result = ImageDiffPairResolver.resolveCommit(entry: file)

        #expect(result.kind == .copied)
        #expect(result.oldPath == "Assets/Original.png")
    }

    @Test func resolvesCommitFileModified() {
        let f = CommitChangedFile(
            path: "logo.png", originalPath: nil, status: "M", add: 0, del: 0
        )
        let r = ImageDiffPairResolver.resolveCommit(entry: f)
        #expect(r.kind == .modified)
    }

    @Test func resolvesMissingEntryAndMissingFileAsDeleted() {
        let r = ImageDiffPairResolver.resolveWorkingCopy(entry: nil, fileExistsOnDisk: false, staged: false)
        #expect(r.kind == .deleted)
        #expect(r.oldPath == nil)
    }

    @Test func resolvesRenameWithoutRenameFromAsModified() {
        // Defensive: git generally pairs "R" with a non-nil rename source,
        // but the data type allows nil. Don't surface .renamed with no path
        // to the loader — it would have nothing to fetch.
        let file = ChangedFile(
            path: "new.png", status: "R", stage: .unstaged,
            add: 0, del: 0, renameFrom: nil
        )
        let r = ImageDiffPairResolver.resolveWorkingCopy(entry: file, fileExistsOnDisk: true, staged: false)
        #expect(r.kind == .modified)
        #expect(r.oldPath == nil)
    }

    @Test func stagedModifiedRemainsModifiedWhenFileMissingFromDisk() {
        // "MD" scenario: staged modification, unstaged deletion. The
        // staged side compares HEAD vs index — both exist regardless of
        // whether the working tree still has the file.
        let file = ChangedFile(
            path: "logo.png", status: "M", stage: .staged,
            add: 0, del: 0, renameFrom: nil
        )
        let r = ImageDiffPairResolver.resolveWorkingCopy(
            entry: file, fileExistsOnDisk: false, staged: true
        )
        #expect(r.kind == .modified)
        #expect(r.oldPath == nil)
    }

    @Test func unstagedModifiedStillFallsBackToDeletedWhenFileMissing() {
        // The pre-existing fallback for stale status is still useful for
        // the unstaged side — a "M" status combined with a missing file
        // usually means status was stale and the file's gone.
        let file = ChangedFile(
            path: "logo.png", status: "M", stage: .unstaged,
            add: 0, del: 0, renameFrom: nil
        )
        let r = ImageDiffPairResolver.resolveWorkingCopy(
            entry: file, fileExistsOnDisk: false, staged: false
        )
        #expect(r.kind == .deleted)
    }
}
