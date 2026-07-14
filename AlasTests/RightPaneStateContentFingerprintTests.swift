import Foundation
import Testing
@testable import Alas

@Suite(.serialized)
struct RightPaneStateContentFingerprintTests {
    @Test func untrackedContentFingerprintHandlesMorePathsThanFoundationLaunchLimit() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-fingerprint-many-paths-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let paths = (0..<4097).map { String(format: "generated-%04d.txt", $0) }
        for path in paths {
            try "same content\n".write(
                to: directory.appendingPathComponent(path),
                atomically: true,
                encoding: .utf8
            )
        }

        let fingerprint = await RightPaneState.untrackedContentFingerprint(paths: paths, worktreePath: directory)

        #expect(fingerprint.contains("generated-0000.txt\u{0000}"))
        #expect(fingerprint.contains("generated-4096.txt\u{0000}"))
        #expect(!fingerprint.contains("hash-error"))
    }
}
