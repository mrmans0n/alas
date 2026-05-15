import Testing
import Foundation
@testable import Alas

struct CommitAIPathTests {
    /// Make a temporary directory that exists on disk, and return its path.
    private func makeDir() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-path-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    @Test func appendsExistingWellKnownDirsToEmptyBase() throws {
        let a = try makeDir()
        let b = try makeDir()
        defer {
            try? FileManager.default.removeItem(atPath: a)
            try? FileManager.default.removeItem(atPath: b)
        }

        let result = CommitAIPath.augment(base: "", wellKnown: [a, b])
        #expect(result == "\(a):\(b)")
    }

    @Test func preservesBaseOrderAndAppendsAfter() throws {
        let extra = try makeDir()
        defer { try? FileManager.default.removeItem(atPath: extra) }

        let result = CommitAIPath.augment(base: "/usr/bin:/bin", wellKnown: [extra])
        #expect(result == "/usr/bin:/bin:\(extra)")
    }

    @Test func skipsWellKnownDirsThatDoNotExist() throws {
        let existing = try makeDir()
        let missing = "/definitely/does/not/exist/\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: existing) }

        let result = CommitAIPath.augment(base: "", wellKnown: [missing, existing])
        #expect(result == existing)
    }

    @Test func skipsWellKnownDirsAlreadyInBase() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let result = CommitAIPath.augment(base: "\(dir):/usr/bin", wellKnown: [dir])
        #expect(result == "\(dir):/usr/bin")
    }

    @Test func expandsTildeInWellKnownPaths() throws {
        let home = NSString("~").expandingTildeInPath
        let result = CommitAIPath.augment(base: "", wellKnown: ["~"])
        #expect(result == home)
    }

    @Test func dedupesByExpandedFormAgainstBase() throws {
        let home = NSString("~").expandingTildeInPath
        let result = CommitAIPath.augment(base: home, wellKnown: ["~"])
        #expect(result == home)
    }

    @Test func augmentedDefaultsToProcessPath() {
        let processPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let result = CommitAIPath.augmented()
        #expect(result.contains(processPath) || processPath.isEmpty)
    }
}
