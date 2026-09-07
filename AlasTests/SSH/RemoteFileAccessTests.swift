import Foundation
import Testing
@testable import Alas

struct RemoteFileAccessTests {
    @Test func readScriptEmitsMtimeHeaderThenBytes() {
        let script = RemoteFileAccess.readScript(path: "/srv/repo/a.txt")
        #expect(script.contains("f='/srv/repo/a.txt'"))
        #expect(script.contains("[ -L \"$f\" ] && exit 5"))
        #expect(script.contains("[ -d \"$f\" ] && exit 3"))
        #expect(script.contains("[ -e \"$f\" ] || exit 4"))
        #expect(script.contains("stat -c %Y -- \"$f\" 2>/dev/null || stat -f %m \"$f\""))
        #expect(script.contains("cat \"$f\""))
    }

    @Test func parseReadPayloadSplitsHeaderFromBinaryBody() {
        var payload = Data("1752249600\n".utf8)
        let body = Data([0x00, 0xFF, 0x0A, 0x42])
        payload.append(body)
        let parsed = RemoteFileAccess.parseReadPayload(payload)
        #expect(parsed?.mtime == Date(timeIntervalSince1970: 1_752_249_600))
        #expect(parsed?.contents == body)
    }

    @Test func parseReadPayloadHandlesEmptyFile() {
        let parsed = RemoteFileAccess.parseReadPayload(Data("42\n".utf8))
        #expect(parsed?.mtime == Date(timeIntervalSince1970: 42))
        #expect(parsed?.contents == Data())
    }

    @Test func parseReadPayloadRejectsGarbageHeader() {
        #expect(RemoteFileAccess.parseReadPayload(Data("not-a-number\nx".utf8)) == nil)
        #expect(RemoteFileAccess.parseReadPayload(Data()) == nil)
    }

    @Test func helperReadPayloadPreservesBinaryBytes() {
        let result = RemoteHelperFSReadResult(
            kind: "file",
            content: nil,
            contentBase64: "AP8KQg==",
            mtime: 42,
            detail: nil
        )
        #expect(RemoteFileAccess.readResult(from: result) == .file(
            data: Data([0x00, 0xFF, 0x0A, 0x42]),
            mtime: Date(timeIntervalSince1970: 42)
        ))
    }

    @Test func helperReadPayloadMapsNonFileKinds() {
        #expect(RemoteFileAccess.readResult(from: RemoteHelperFSReadResult(
            kind: "missing", content: nil, contentBase64: nil, mtime: nil, detail: nil
        )) == .missing)
        #expect(RemoteFileAccess.readResult(from: RemoteHelperFSReadResult(
            kind: "directory", content: nil, contentBase64: nil, mtime: nil, detail: nil
        )) == .directory)
        #expect(RemoteFileAccess.readResult(from: RemoteHelperFSReadResult(
            kind: "symlink", content: nil, contentBase64: nil, mtime: nil, detail: nil
        )) == .symlink)
    }

    @Test func writeScriptPreservesPermissionsAndIsAtomic() {
        let script = RemoteFileAccess.writeScript(path: "/srv/repo/run.sh")
        #expect(script.contains("f='/srv/repo/run.sh'"))
        #expect(script.contains("[ -L \"$f\" ] && exit 6"))
        #expect(script.contains("[ -d \"$f\" ] && exit 7"))
        #expect(script.contains("mode=$(stat -c %a -- \"$f\" 2>/dev/null || stat -f %Lp \"$f\")"))
        #expect(script.contains("cp -p \"$f\" \"$t\""))
        #expect(script.contains("chmod u+w \"$t\""))
        #expect(script.contains("cat > \"$t\""))
        #expect(script.contains("chmod \"$mode\" \"$t\""))
        #expect(script.contains("mv \"$t\" \"$f\""))
        #expect(script.contains("rm -f \"$t\""))
        #expect(script.contains("stat -c %Y -- \"$f\" 2>/dev/null || stat -f %m \"$f\""))
    }

    @Test func scriptsQuoteApostrophePaths() {
        let read = RemoteFileAccess.readScript(path: "/srv/o'brien.txt")
        #expect(read.contains("f='/srv/o'\\''brien.txt'"))
    }

    @Test func saveGateDecisions() {
        let t1 = Date(timeIntervalSince1970: 100)
        let t2 = Date(timeIntervalSince1970: 200)
        #expect(RemoteSaveGate.decision(originalMtime: t1, remoteMtime: t1) == .proceed)
        #expect(RemoteSaveGate.decision(originalMtime: t1, remoteMtime: t2) == .conflict)
        #expect(RemoteSaveGate.decision(originalMtime: t1, remoteMtime: nil) == .targetDeleted)
        #expect(RemoteSaveGate.decision(originalMtime: nil, remoteMtime: nil) == .proceed)
        #expect(RemoteSaveGate.decision(originalMtime: t2, remoteMtime: t1) == .proceed)
    }

    @Test func sizeScriptChainsGnuThenBsdStat() {
        let script = RemoteFileAccess.sizeScript(path: "/srv/repo/a.txt")
        #expect(script.contains("f='/srv/repo/a.txt'"))
        #expect(script.contains("stat -c %s -- \"$f\" 2>/dev/null || stat -f %z \"$f\""))
    }

    /// Runs the exact generated `sizeScript` locally via `/bin/sh -c` against
    /// a real file of known size — proving the GNU/BSD `stat` fallback chain
    /// actually parses to the right byte count on this host's shell, without
    /// a real SSH connection. `RemoteFileAccess.size`'s helper-first /
    /// exec-fallback dispatch and its threading into
    /// `AppState.readRemoteWorktreeFileRaw`'s new `.tooLarge` outcome are
    /// NOT covered by this test — there is no reachable SSH host, and no
    /// mock seam for `RemoteHelperClient`/`RemoteExec`, to drive that
    /// end-to-end in this environment.
    @Test func sizeScriptReportsTheRealByteCountWhenRunLocally() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-size-script-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: file) }
        let content = String(repeating: "x", count: 12345)
        try content.write(to: file, atomically: true, encoding: .utf8)

        let script = RemoteFileAccess.sizeScript(path: file.path)
        let result = try await Process.run("/bin/sh", args: ["-c", script])

        #expect(result.exitCode == 0)
        #expect(UInt64(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) == 12345)
    }

    @Test func saveGateTreatsEqualMtimeAsAmbiguousForCallerContentCheck() {
        let baseline = Date(timeIntervalSince1970: 100)
        #expect(RemoteSaveGate.requiresContentCheck(originalMtime: baseline, remoteMtime: baseline))
        #expect(RemoteSaveGate.requiresContentCheck(originalMtime: baseline, remoteMtime: Date(timeIntervalSince1970: 99)))
        #expect(!RemoteSaveGate.requiresContentCheck(originalMtime: baseline, remoteMtime: Date(timeIntervalSince1970: 101)))
        #expect(!RemoteSaveGate.requiresContentCheck(originalMtime: nil, remoteMtime: baseline))
        #expect(!RemoteSaveGate.requiresContentCheck(originalMtime: baseline, remoteMtime: nil))
    }
}
