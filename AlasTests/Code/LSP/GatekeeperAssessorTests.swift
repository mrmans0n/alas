import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("GatekeeperAssessor")
struct GatekeeperAssessorTests {
    @Test("first lookup invokes the underlying assessor")
    func firstLookupRuns() throws {
        let path = try makeTempExecutable()
        defer { try? FileManager.default.removeItem(atPath: path) }
        var calls = 0
        let assessor = GatekeeperAssessor(runner: { _ in
            calls += 1
            return .allowed
        })
        #expect(assessor.assess(realPath: path) == .allowed)
        #expect(calls == 1)
    }

    @Test("second lookup with unchanged file hits the cache")
    func cachedSecondLookup() throws {
        let path = try makeTempExecutable()
        defer { try? FileManager.default.removeItem(atPath: path) }
        var calls = 0
        let assessor = GatekeeperAssessor(runner: { _ in
            calls += 1
            return .rejected
        })
        _ = assessor.assess(realPath: path)
        let second = assessor.assess(realPath: path)
        #expect(second == .rejected)
        #expect(calls == 1)
    }

    @Test("cache entry invalidated when file mtime changes")
    func mtimeChangeInvalidatesCache() throws {
        let path = try makeTempExecutable()
        defer { try? FileManager.default.removeItem(atPath: path) }
        var calls = 0
        let assessor = GatekeeperAssessor(runner: { _ in
            calls += 1
            return calls == 1 ? .rejected : .allowed
        })
        _ = assessor.assess(realPath: path)
        // Bump mtime by writing again
        try "changed".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        let second = assessor.assess(realPath: path)
        #expect(second == .allowed)
        #expect(calls == 2)
    }

    @Test("invalidateAll forces re-assessment")
    func invalidateAllForcesReassessment() throws {
        let path = try makeTempExecutable()
        defer { try? FileManager.default.removeItem(atPath: path) }
        var calls = 0
        let assessor = GatekeeperAssessor(runner: { _ in
            calls += 1
            return .allowed
        })
        _ = assessor.assess(realPath: path)
        assessor.invalidateAll()
        _ = assessor.assess(realPath: path)
        #expect(calls == 2)
    }

    @Test("runner throws → unknown")
    func runnerErrorBecomesUnknown() throws {
        let path = try makeTempExecutable()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let assessor = GatekeeperAssessor(runner: { _ in
            throw NSError(domain: "test", code: 1)
        })
        #expect(assessor.assess(realPath: path) == .unknown)
    }

    @Test("non-existent file runs runner on every call (no cache write)")
    func missingFileSkipsCache() throws {
        let path = "/tmp/definitely-does-not-exist-\(UUID().uuidString)"
        var calls = 0
        let assessor = GatekeeperAssessor(runner: { _ in
            calls += 1
            return .unknown
        })
        _ = assessor.assess(realPath: path)
        _ = assessor.assess(realPath: path)
        #expect(calls == 2)
    }

    @Test("quarantine flag without approved bit → rejected")
    func quarantineFlagBlocks() {
        // 0083: quarantined (bit 0x01), download finished (0x80), no approval.
        #expect(GatekeeperAssessor.interpretQuarantineValue("0083;abcd;Safari;UUID") == .rejected)
    }

    @Test("quarantine flag with approved bit (0x40) → allowed")
    func approvedQuarantineFlagAllows() {
        // 01c3: previous + LSQuarantineUserApproved (0x40). Sample from the
        // stackoverflow post Codex linked: 0183 → 01c3 after user approval.
        #expect(GatekeeperAssessor.interpretQuarantineValue("01c3;abcd;Safari;UUID") == .allowed)
    }

    @Test("unparseable flag field → unknown")
    func unparseableFlagsBecomeUnknown() {
        #expect(GatekeeperAssessor.interpretQuarantineValue("not-hex;abcd;X;Y") == .unknown)
    }

    @Test("approved-only flag (0x40) → allowed")
    func approvedFlagAloneAllows() {
        #expect(GatekeeperAssessor.interpretQuarantineValue("0040") == .allowed)
    }

    private func makeTempExecutable() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("bin").path
        FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }
}
