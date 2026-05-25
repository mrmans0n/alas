import Testing
import Foundation
@testable import Alas

struct MergeWordDiffTests {
    @Test func identicalStringsReportAllUnchanged() {
        let result = MergeWordDiff.diff(local: "let x = 1", remote: "let x = 1", mode: .characters)
        #expect(result.localChanged.isEmpty)
        #expect(result.remoteChanged.isEmpty)
    }

    @Test func singleCharDifferenceIsIsolated() {
        let result = MergeWordDiff.diff(local: "let x = 1", remote: "let x = 2", mode: .characters)
        #expect(result.localChanged == [NSRange(location: 8, length: 1)])
        #expect(result.remoteChanged == [NSRange(location: 8, length: 1)])
    }

    @Test func wordModeSnapsToWordBoundaries() {
        let result = MergeWordDiff.diff(local: "let host = local", remote: "let host = remote", mode: .words)
        #expect(result.localChanged.count == 1)
        #expect(result.remoteChanged.count == 1)
        let localRange = result.localChanged[0]
        let remoteRange = result.remoteChanged[0]
        #expect(("let host = local" as NSString).substring(with: localRange) == "local")
        #expect(("let host = remote" as NSString).substring(with: remoteRange) == "remote")
    }

    @Test func offModeReturnsEmpty() {
        let result = MergeWordDiff.diff(local: "a", remote: "b", mode: .off)
        #expect(result.localChanged.isEmpty)
        #expect(result.remoteChanged.isEmpty)
    }

    @Test func emptyStringsAreSafe() {
        let result = MergeWordDiff.diff(local: "", remote: "", mode: .characters)
        #expect(result.localChanged.isEmpty)
        #expect(result.remoteChanged.isEmpty)
    }
}
