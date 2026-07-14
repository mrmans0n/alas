import Testing
import Foundation
@testable import Alas

@Suite(.serialized)
struct TerminalCLIInjectionTests {
    /// A tiny executable used as the "bundled" source in tests.
    private func makeStubBinary(_ marker: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-stub-\(UUID().uuidString)")
        try "#!/bin/sh\necho \(marker)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test func installsAlasAndAoFromSource() throws {
        let source = try makeStubBinary("v1")
        let dir = try TerminalCLIInjection.installExecutables(sourceBinary: source)

        for name in ["alas", "ao"] {
            let url = dir.appendingPathComponent(name)
            #expect(FileManager.default.isExecutableFile(atPath: url.path))
            #expect(try Data(contentsOf: url) == (try Data(contentsOf: source)))
        }
    }

    @Test func rewritesWhenBundledBinaryChanges() throws {
        let v1 = try makeStubBinary("v1")
        let dir = try TerminalCLIInjection.installExecutables(sourceBinary: v1)
        let alas = dir.appendingPathComponent("alas")
        let firstMtime = try FileManager.default.attributesOfItem(atPath: alas.path)[.modificationDate] as? Date

        let v2 = try makeStubBinary("v2-different-length")
        _ = try TerminalCLIInjection.installExecutables(sourceBinary: v2)
        #expect(try Data(contentsOf: alas) == (try Data(contentsOf: v2)))
        _ = firstMtime // presence check only; content is authoritative
    }

    @Test func idempotentWhenSourceUnchanged() throws {
        let source = try makeStubBinary("same")
        let dir1 = try TerminalCLIInjection.installExecutables(sourceBinary: source)
        let before = try Data(contentsOf: dir1.appendingPathComponent("alas"))
        let dir2 = try TerminalCLIInjection.installExecutables(sourceBinary: source)
        #expect(dir1.path == dir2.path)
        #expect(try Data(contentsOf: dir2.appendingPathComponent("alas")) == before)
    }

    @Test func pathValueUsesSystemFallbackWhenCurrentPathIsEmpty() {
        let value = TerminalCLIInjection.pathValue(prepending: "/tmp/alas-bin", to: nil)
        #expect(value.hasPrefix("/tmp/alas-bin:"))
        #expect(value.contains("/usr/bin"))
        #expect(value.contains("/bin"))
    }
}
