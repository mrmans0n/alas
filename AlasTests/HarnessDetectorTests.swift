import Foundation
import Testing
@testable import Alas

struct HarnessDetectorTests {
    /// A persistent pane's Ghostty PTY contains the zmx client. Detection
    /// must follow the foreground job in the persistent shell's own PTY.
    @Test(.enabled(if: ZmxEnv.resolve().isAvailable, "requires bundled zmx"),
          arguments: [("claude", HarnessKind.claudeCode), ("codex", HarnessKind.codex)])
    func detectsManuallyLaunchedAgentInPersistentTerminal(name: String, expected: HarnessKind) async throws {
        let client = ZmxClient(env: ZmxEnv.resolve())
        let directory = URL(fileURLWithPath: try zmxShortTempDirectory(), isDirectory: true)
        let sessionName = "detect-\(UUID().uuidString.prefix(8))"
        defer {
            client.killSession(name: sessionName)
            try? FileManager.default.removeItem(at: directory)
        }
        // Use a harmless executable with the agent's name, without starting
        // an authenticated CLI or installing hooks in the developer's home.
        let binary = directory.appendingPathComponent(name)
        try Data(contentsOf: URL(fileURLWithPath: "/bin/sleep")).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let signing = SubprocessRunner.system.run(
            URL(fileURLWithPath: "/usr/bin/codesign"), ["--force", "--sign", "-", binary.path], [:], 5)
        try #require(signing.exitCode == 0, "sign test executable: \(signing.stderr)")
        let launch = try #require(HostShellLaunch.make(
            zmx: client, sessionName: sessionName, directory: directory,
            shell: "/bin/bash", shellArguments: ["--noprofile", "--norc", "-i"],
            baseEnvironment: ProcessInfo.processInfo.environment))
        try await launch.run()
        let socket = try ZmxIPCSocket.connect(path: #require(client.socketPath(forSession: sessionName)))
        defer { socket.shutdown() }
        let pidFile = directory.appendingPathComponent("agent-pid")
        let command = "/bin/bash -c 'echo $$ > \(pidFile.path); exec \(binary.path) 60'\n"
        try #require(socket.write(ZmxIPC.encode(.send, Data(command.utf8), wire: ZmxIPC.bundledWire)))
        try await eventually("foreground agent") {
            guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
                  let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
            return HarnessDetector.matchKind(pid: pid) == expected
        }
        let session = await MainActor.run {
            TerminalSession(
                id: sessionName, worktreeId: "wt", projectId: "project",
                surface: AlasGhostty.SurfaceView(testIO: FakeGhosttySurfaceIO()),
                executable: launch.executable.path, args: ["attach", sessionName],
                zmxSessionName: sessionName)
        }
        let detector = HarnessDetector()
        await session.registerForegroundPid(with: detector)
        let pid = await Task.detached { detector.foregroundPid(sessionId: sessionName) }.value
        let kind = pid.flatMap { HarnessDetector.matchKind(pid: $0) }
        #expect(kind == expected)
        let service = HarnessService()
        service.recordHarnessDetection(sessionId: sessionName, kind: kind)
        #expect(service.activityBySession[sessionName]?.agent == expected.asAgentKind)
        #expect(service.activityBySession[sessionName]?.state == .busy)
        withExtendedLifetime(session) {}
    }

    /// Every built-in agent has to resolve to the harness the detector will
    /// report for it, or a scheduled prompt aimed at that agent is refused
    /// before it is ever typed. Cursor is the reason this is not a plain
    /// `AgentKind(rawValue:)`: it is registered as `cursor-agent`.
    @Test func everyBuiltinAgentResolvesToItsHarness() {
        #expect(HarnessKind.forAgentID("cursor-agent") == .cursor)
        #expect(HarnessKind.forAgentID("claude") == .claudeCode)
        #expect(HarnessKind.forAgentID("codex") == .codex)
        for builtin in AgentBuiltins.catalog {
            #expect(
                HarnessKind.forAgentID(builtin.id) != nil,
                "Built-in agent \(builtin.id) resolves to no harness, so it can never be confirmed ready"
            )
        }
        // A custom agent is not recognisable in a terminal, and saying so is
        // what keeps a prompt from being typed at whatever else is running.
        #expect(HarnessKind.forAgentID("my-custom-agent") == nil)
    }

    /// A custom agent has a UUID for an id, so only the binary it launches
    /// says what will be running. Wrapping a known CLI is the common case
    /// and has to stay identifiable, or its prompts are refused.
    @Test func aCustomAgentIsIdentifiedByItsBinary() {
        let uuid = "9C4E2A10-0000-4000-8000-000000000000"
        #expect(HarnessKind.forAgent(id: uuid, binary: "claude") == .claudeCode)
        #expect(HarnessKind.forAgent(id: uuid, binary: "/opt/homebrew/bin/codex") == .codex)
        #expect(HarnessKind.forAgent(id: uuid, binary: "~/bin/cursor-agent") == .cursor)
        // Nothing recognisable means readiness cannot be established, which
        // is the safe answer rather than trusting any harness that appears.
        #expect(HarnessKind.forAgent(id: uuid, binary: "my-own-wrapper") == nil)
        // A built-in id still wins, whatever its binary override says.
        #expect(HarnessKind.forAgent(id: "cursor-agent", binary: "/usr/bin/true") == .cursor)
    }

    /// The detector polls on its own queue. The provider is created in the
    /// app module, which reaches AlasCore through `@_exported import`, so a
    /// main-actor-isolated provider would trap on its executor check there.
    @MainActor
    @Test func terminalSessionPidProviderRunsOffMain() async {
        let session = TerminalSession(
            id: "leaf",
            worktreeId: "wt",
            projectId: "proj",
            surface: AlasGhostty.SurfaceView(testIO: FakeGhosttySurfaceIO()),
            executable: "/bin/zsh",
            args: []
        )
        let detector = HarnessDetector()
        session.registerForegroundPid(with: detector)
        let pid = await Task.detached { detector.foregroundPid(sessionId: "leaf") }.value
        // A test surface has no Ghostty surface, so there is no foreground pid.
        #expect(pid == nil)
        withExtendedLifetime(session) {}
    }

    @Test func matchesClaudeProcess() {
        #expect(HarnessDetector.matchKind(processName: "claude") == .claudeCode)
        #expect(HarnessDetector.matchKind(processName: "claude-code") == .claudeCode)
    }
    @Test func matchesCodex() {
        #expect(HarnessDetector.matchKind(processName: "codex-cli") == .codex)
    }
    @Test func matchesCursor() {
        #expect(HarnessDetector.matchKind(processName: "cursor-agent") == .cursor)
    }
    @Test func matchesAdditionalAgentProcesses() {
        #expect(HarnessDetector.matchKind(processName: "gemini") == .gemini)
        #expect(HarnessDetector.matchKind(processName: "opencode") == .opencode)
        #expect(HarnessDetector.matchKind(processName: "opencode2") == .opencode)
        #expect(HarnessDetector.matchKind(processName: "pi") == .pi)
        #expect(HarnessDetector.matchKind(processName: "omp") == .omp)
        #expect(HarnessDetector.matchKind(processName: "copilot") == .copilot)
    }
    @Test func unknownReturnsNil() {
        #expect(HarnessDetector.matchKind(processName: "zsh") == nil)
    }
    @Test func matchesCodexHomebrewBinary() {
        #expect(HarnessDetector.matchKind(processName: "codex-aarch64-apple-darwin") == .codex)
    }
    @Test func matchesAnyDashSuffix() {
        #expect(HarnessDetector.matchKind(processName: "cursor-agent-dev") == .cursor)
        #expect(HarnessDetector.matchKind(processName: "copilot-dev") == .copilot)
    }
    @Test func doesNotPrefixMatchShortProcessNames() {
        #expect(HarnessDetector.matchKind(processName: "pi-dev") == nil)
    }
    @Test func doesNotMatchSubstring() {
        #expect(HarnessDetector.matchKind(processName: "claudefoo") == nil)
    }
}
