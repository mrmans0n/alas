import Foundation
import Testing
import AlasAgentKit

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
}
