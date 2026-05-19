import Testing
@testable import Alas

@Suite("HookInstallNudgeResolver")
struct HookInstallNudgeResolverTests {
    struct StubInstaller: AgentInstaller, Sendable {
        let agent: AgentKind
        var state: InstallState
        func installState() -> InstallState { state }
        func install() async throws {}
        func uninstall() throws {}
    }

    private func registry(with states: [AgentKind: InstallState]) -> (AgentKind) -> InstallState {
        return { agent in
            states[agent] ?? .notInstalled
        }
    }

    private func alwaysExists(_: AgentKind) -> Bool { true }
    private func neverExists(_: AgentKind) -> Bool { false }

    @Test("supported detected agent with .notInstalled returns install nudge")
    func notInstalledNudge() {
        let nudge = HookInstallNudgeResolver.resolve(
            detectedHarnesses: [.claudeCode],
            dismissed: [],
            installState: registry(with: [.claude: .notInstalled]),
            installerExists: alwaysExists
        )
        #expect(nudge != nil)
        #expect(nudge?.agent == .claude)
        #expect(nudge?.installState == .notInstalled)
        #expect(nudge?.actionTitle == "Install")
        #expect(nudge?.title == "Install Claude Code hook for terminal status")
    }

    @Test("supported detected agent with .outdated returns update nudge")
    func outdatedNudge() {
        let nudge = HookInstallNudgeResolver.resolve(
            detectedHarnesses: [.codex],
            dismissed: [],
            installState: registry(with: [.codex: .outdated]),
            installerExists: alwaysExists
        )
        #expect(nudge != nil)
        #expect(nudge?.agent == .codex)
        #expect(nudge?.installState == .outdated)
        #expect(nudge?.actionTitle == "Update")
        #expect(nudge?.title == "Update Codex hook for terminal status")
    }

    @Test("supported detected agent with .installed returns nil")
    func installedReturnsNil() {
        let nudge = HookInstallNudgeResolver.resolve(
            detectedHarnesses: [.cursor],
            dismissed: [],
            installState: registry(with: [.cursor: .installed]),
            installerExists: alwaysExists
        )
        #expect(nudge == nil)
    }

    @Test("dismissed agent returns nil")
    func dismissedReturnsNil() {
        let nudge = HookInstallNudgeResolver.resolve(
            detectedHarnesses: [.claudeCode],
            dismissed: [AgentKind.claude.rawValue],
            installState: registry(with: [.claude: .notInstalled]),
            installerExists: alwaysExists
        )
        #expect(nudge == nil)
    }

    @Test("unsupported or unrelated terminal activity returns nil")
    func unrelatedReturnsNil() {
        let nudge = HookInstallNudgeResolver.resolve(
            detectedHarnesses: [],
            dismissed: [],
            installState: registry(with: [:]),
            installerExists: alwaysExists
        )
        #expect(nudge == nil)
    }

    @Test("missing installer returns nil")
    func missingInstallerReturnsNil() {
        let nudge = HookInstallNudgeResolver.resolve(
            detectedHarnesses: [.claudeCode],
            dismissed: [],
            installState: registry(with: [.claude: .notInstalled]),
            installerExists: neverExists
        )
        #expect(nudge == nil)
    }

    @Test("multiple detected sessions prefer first actionable supported agent")
    func multipleSessions() {
        let nudge = HookInstallNudgeResolver.resolve(
            detectedHarnesses: [.cursor, .claudeCode],
            dismissed: [],
            installState: registry(with: [.cursor: .installed, .claude: .notInstalled]),
            installerExists: alwaysExists
        )
        #expect(nudge != nil)
        #expect(nudge?.agent == .claude)
    }

    @Test("all actionable agents installed returns nil")
    func allInstalledReturnsNil() {
        let nudge = HookInstallNudgeResolver.resolve(
            detectedHarnesses: [.claudeCode, .codex, .cursor],
            dismissed: [],
            installState: registry(with: [.claude: .installed, .codex: .installed, .cursor: .installed]),
            installerExists: alwaysExists
        )
        #expect(nudge == nil)
    }
}
