import Darwin
import Foundation
import Testing
import AlasAgentKit
import AlasPlatform

struct HarnessDetectorTests {
    @Test(arguments: [
        (".local/share/claude/versions/2.1.310", HarnessKind.claudeCode as HarnessKind?),
        (".local/share/other/versions/2.1.310", nil),
        (".local/share/claude/versions/unknown", nil),
    ])
    func detectsNativeClaudeFromResolvedExecutablePath(path: String, expected: HarnessKind?) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("alas-harness-\(UUID().uuidString)")
        let executable = root.appendingPathComponent(path)
        let launcher = root.appendingPathComponent("claude")
        try fm.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try fm.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executable)
        try fm.createSymbolicLink(at: launcher, withDestinationURL: executable)

        let process = Process()
        process.executableURL = launcher
        process.arguments = ["30"]
        try process.run()
        defer {
            process.terminate()
            process.waitUntilExit()
        }

        #expect(HarnessDetector.matchKind(pid: process.processIdentifier) == expected)
    }

    @Test(arguments: [HarnessKind.codex, .claudeCode])
    func detectsCodexBehindNodeLauncher(childKind: HarnessKind) async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("alas-harness-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let launcher = root.appendingPathComponent("node")
        let executable = root.appendingPathComponent(try #require(childKind.processNames.first))
        let pidFile = root.appendingPathComponent("child-pid")
        // Simulate the npm launcher with a shell that stays alive while its child runs.
        try fm.copyItem(at: URL(fileURLWithPath: "/bin/bash"), to: launcher)
        let signing = SubprocessRunner.system.run(
            URL(fileURLWithPath: "/usr/bin/codesign"), ["--force", "--sign", "-", launcher.path], [:], 5)
        try #require(signing.exitCode == 0, "Sign test launcher: \(signing.stderr)")
        try fm.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executable)

        let process = Process()
        process.executableURL = launcher
        process.arguments = ["-c", """
        "$1" 60 &
        child=$!
        trap 'kill "$child"; wait "$child"; exit' TERM
        printf '%s' "$child" > "$2"
        wait "$child"
        """, "node", executable.path, pidFile.path]
        try process.run()
        defer {
            process.terminate()
            process.waitUntilExit()
        }

        let launcherPID = process.processIdentifier
        try await eventually(within: .seconds(15)) {
            guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
                  let pid = pid_t(text) else { return false }
            return getpgid(pid) == getpgid(launcherPID) && HarnessDetector.matchKind(pid: pid) == childKind
        }

        #expect(HarnessDetector.matchKind(pid: launcherPID) == (childKind == .codex ? .codex : nil))
    }
}
