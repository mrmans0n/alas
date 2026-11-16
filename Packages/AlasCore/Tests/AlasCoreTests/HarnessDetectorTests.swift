// The fixtures copy /bin/sleep under new names; on Linux it is often a multicall
// binary (coreutils) that dispatches on its name, so the copies never run.
#if os(macOS)
import Darwin
import Foundation
import Testing
import AlasAgentKit
import AlasFoundation
import AlasPlatform

struct HarnessDetectorTests {
    @Test(arguments: [
        (".local/share/claude/versions/2.1.310", HarnessKind.claudeCode as HarnessKind?),
        (".local/share/other/versions/2.1.310", nil),
        (".local/share/claude/versions/unknown", nil),
    ])
    func detectsNativeClaudeFromResolvedExecutablePath(path: String, expected: HarnessKind?) async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("alas-harness-\(UUID().uuidString)")
        let executable = root.appendingPathComponent(path)
        let launcher = root.appendingPathComponent("claude")
        try fm.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try fm.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executable)
        try fm.createSymbolicLink(at: launcher, withDestinationURL: executable)

        let process = try SpawnedProcess(executable: launcher, arguments: ["30"],
            environment: ProcessInfo.processInfo.environment, stdin: nil, stdout: Pipe(), stderr: Pipe(),
            onExit: { _, _ in })
        defer { process.terminate() }

        #expect(HarnessDetector.matchKind(pid: process.pid) == expected)
        process.terminate()
        try await eventually { !process.isRunning }
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
        // Re-sign the copy before bash execs it; macOS can reject the copied system signature.
        let childSigning = SubprocessRunner.system.run(
            URL(fileURLWithPath: "/usr/bin/codesign"), ["--force", "--sign", "-", executable.path], [:], 5)
        try #require(childSigning.exitCode == 0, "Sign test child: \(childSigning.stderr)")

        let arguments = ["-c", """
        "$1" 60 &
        child=$!
        trap 'kill "$child"; wait "$child"; exit' TERM
        printf '%s' "$child" > "$2"
        wait "$child"
        """, "node", executable.path, pidFile.path]
        // Foundation's waitUntilExit can remain in its run loop after the shell
        // exits. Use the dedicated reaper and await its state without blocking a worker.
        let process = try SpawnedProcess(executable: launcher, arguments: arguments,
            environment: ProcessInfo.processInfo.environment, stdin: nil, stdout: Pipe(), stderr: Pipe(),
            onExit: { _, _ in })
        defer { process.terminate() }

        let launcherPID = process.pid
        try await eventually(within: .seconds(15)) {
            guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
                  let pid = pid_t(text) else { return false }
            return getpgid(pid) == getpgid(launcherPID) && HarnessDetector.matchKind(pid: pid) == childKind
        }

        #expect(HarnessDetector.matchKind(pid: launcherPID) == (childKind == .codex ? .codex : nil))
        process.terminate()
        try await eventually { !process.isRunning }
    }
}
#endif
