import Testing
@testable import Alas

struct WorktreeStatusParserTests {
    private func parse(_ entries: [String]) -> WorktreeDirtyState {
        // git terminates every record with NUL, including the last.
        WorktreeStatusScanner.parse(porcelainZ: entries.map { $0 + "\0" }.joined())
    }

    @Test func emptyOutputIsClean() {
        #expect(WorktreeStatusScanner.parse(porcelainZ: "") == .clean)
    }

    @Test func scannerRequestsIndividualUntrackedFiles() {
        #expect(WorktreeStatusScanner.statusArguments.contains("--untracked-files=all"))
    }

    @Test func countsOneEntryPerChangedPath() {
        #expect(parse([" M a.swift", "?? b.swift", "A  c.swift"])
            == .dirty(fileCount: 3, conflictCount: 0))
    }

    @Test func pathsWithSpacesAndNewlinesCountOnce() {
        // The whole reason for -z. A line-based parse counts the second as two.
        #expect(parse([" M my file.swift", " M weird\nname.swift"])
            == .dirty(fileCount: 2, conflictCount: 0))
    }

    @Test func renameConsumesItsSourcePathWithoutCounting() {
        // "R  new\0old\0" is ONE changed file across TWO NUL-separated fields.
        let output = "R  new.swift\0old.swift\0 M other.swift\0"
        #expect(WorktreeStatusScanner.parse(porcelainZ: output)
            == .dirty(fileCount: 2, conflictCount: 0))
    }

    @Test func copyAlsoConsumesItsSourcePath() {
        let output = "C  copy.swift\0origin.swift\0"
        #expect(WorktreeStatusScanner.parse(porcelainZ: output)
            == .dirty(fileCount: 1, conflictCount: 0))
    }

    @Test func unmergedEntriesCountAsBothFileAndConflict() {
        #expect(parse(["UU a.swift", "AU b.swift", "UD c.swift"])
            == .dirty(fileCount: 3, conflictCount: 3))
    }

    @Test func bothAddedAndBothDeletedAreConflicts() {
        // AA and DD contain no "U" but are unmerged states.
        #expect(parse(["AA a.swift", "DD b.swift"])
            == .dirty(fileCount: 2, conflictCount: 2))
    }

    @Test func mixedDirtyAndConflictedCountsSeparately() {
        #expect(parse([" M a.swift", "UU b.swift", "?? c.swift"])
            == .dirty(fileCount: 3, conflictCount: 1))
    }

    @Test func toleratesMissingTrailingNul() {
        #expect(WorktreeStatusScanner.parse(porcelainZ: " M a.swift")
            == .dirty(fileCount: 1, conflictCount: 0))
    }

    @Test func unmergedCodesAreClassifiedCorrectly() {
        for code in ["UU", "AU", "UD", "DU", "UA", "AA", "DD"] {
            #expect(WorktreeStatusScanner.isUnmerged(code), "\(code) should be unmerged")
        }
        for code in [" M", "M ", "??", "A ", "R ", "C ", "D "] {
            #expect(!WorktreeStatusScanner.isUnmerged(code), "\(code) should not be unmerged")
        }
    }
}
