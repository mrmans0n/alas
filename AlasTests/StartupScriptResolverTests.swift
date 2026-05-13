import Testing
import Foundation
@testable import Alas

struct StartupScriptResolverTests {
    // MARK: - Helpers

    private func makeProject(mode: ProjectStartupScriptMode, script: String, worktreeMode: ProjectStartupScriptMode = .useGlobal, worktreeScript: String = "") -> ProjectConfig {
        ProjectConfig(
            id: "p1",
            name: "test",
            path: "/tmp/test",
            color: "#5fb7c4",
            addedAt: Date(),
            startupScripts: ProjectStartupScripts(
                sessionOpenMode: mode,
                sessionOpenScript: script,
                worktreeCreateMode: worktreeMode,
                worktreeCreateScript: worktreeScript
            )
        )
    }

    private func makeTerminal(startupScript: String, worktreeCreateScript: String = "") -> AppConfig.Terminal {
        var t = AppConfig.defaults.terminal
        t.startupScript = startupScript
        t.worktreeCreateScript = worktreeCreateScript
        return t
    }

    // MARK: - useGlobal

    @Test func useGlobalReturnsGlobalScript() {
        let t = makeTerminal(startupScript: "echo global")
        let p = makeProject(mode: .useGlobal, script: "echo local")
        #expect(StartupScriptResolver.sessionOpenScript(global: t, project: p) == "echo global")
    }

    @Test func useGlobalReturnsEmptyWhenGlobalEmpty() {
        let t = makeTerminal(startupScript: "")
        let p = makeProject(mode: .useGlobal, script: "echo local")
        #expect(StartupScriptResolver.sessionOpenScript(global: t, project: p) == "")
    }

    // MARK: - appendToGlobal

    @Test func appendToGlobalConcatenatesBoth() {
        let t = makeTerminal(startupScript: "echo global")
        let p = makeProject(mode: .appendToGlobal, script: "echo local")
        #expect(StartupScriptResolver.sessionOpenScript(global: t, project: p) == "echo global\necho local")
    }

    @Test func appendToGlobalReturnsGlobalOnlyWhenLocalEmpty() {
        let t = makeTerminal(startupScript: "echo global")
        let p = makeProject(mode: .appendToGlobal, script: "")
        #expect(StartupScriptResolver.sessionOpenScript(global: t, project: p) == "echo global")
    }

    @Test func appendToGlobalReturnsLocalOnlyWhenGlobalEmpty() {
        let t = makeTerminal(startupScript: "")
        let p = makeProject(mode: .appendToGlobal, script: "echo local")
        #expect(StartupScriptResolver.sessionOpenScript(global: t, project: p) == "echo local")
    }

    @Test func appendToGlobalReturnsEmptyWhenBothEmpty() {
        let t = makeTerminal(startupScript: "")
        let p = makeProject(mode: .appendToGlobal, script: "")
        #expect(StartupScriptResolver.sessionOpenScript(global: t, project: p) == "")
    }

    // MARK: - overrideGlobal

    @Test func overrideGlobalReturnsLocalScript() {
        let t = makeTerminal(startupScript: "echo global")
        let p = makeProject(mode: .overrideGlobal, script: "echo local")
        #expect(StartupScriptResolver.sessionOpenScript(global: t, project: p) == "echo local")
    }

    @Test func overrideGlobalReturnsEmptyWhenLocalEmpty() {
        let t = makeTerminal(startupScript: "echo global")
        let p = makeProject(mode: .overrideGlobal, script: "")
        #expect(StartupScriptResolver.sessionOpenScript(global: t, project: p) == "")
    }

    // MARK: - disabled

    @Test func disabledReturnsEmptyRegardlessOfScripts() {
        let t = makeTerminal(startupScript: "echo global")
        let p = makeProject(mode: .disabled, script: "echo local")
        #expect(StartupScriptResolver.sessionOpenScript(global: t, project: p) == "")
    }

    // MARK: - Whitespace trimming

    @Test func trimsLeadingAndTrailingWhitespace() {
        let t = makeTerminal(startupScript: "  echo global  ")
        let p = makeProject(mode: .useGlobal, script: "  echo local  ")
        #expect(StartupScriptResolver.sessionOpenScript(global: t, project: p) == "echo global")
    }

    // MARK: - Worktree create scripts

    @Test func worktreeCreateUseGlobal() {
        let t = makeTerminal(startupScript: "", worktreeCreateScript: "echo wt-global")
        let p = makeProject(mode: .useGlobal, script: "", worktreeMode: .useGlobal, worktreeScript: "echo wt-local")
        #expect(StartupScriptResolver.worktreeCreateScript(global: t, project: p) == "echo wt-global")
    }

    @Test func worktreeCreateAppendToGlobal() {
        let t = makeTerminal(startupScript: "", worktreeCreateScript: "echo wt-global")
        let p = makeProject(mode: .useGlobal, script: "", worktreeMode: .appendToGlobal, worktreeScript: "echo wt-local")
        #expect(StartupScriptResolver.worktreeCreateScript(global: t, project: p) == "echo wt-global\necho wt-local")
    }

    @Test func worktreeCreateOverrideGlobal() {
        let t = makeTerminal(startupScript: "", worktreeCreateScript: "echo wt-global")
        let p = makeProject(mode: .useGlobal, script: "", worktreeMode: .overrideGlobal, worktreeScript: "echo wt-local")
        #expect(StartupScriptResolver.worktreeCreateScript(global: t, project: p) == "echo wt-local")
    }

    @Test func worktreeCreateDisabled() {
        let t = makeTerminal(startupScript: "", worktreeCreateScript: "echo wt-global")
        let p = makeProject(mode: .useGlobal, script: "", worktreeMode: .disabled, worktreeScript: "echo wt-local")
        #expect(StartupScriptResolver.worktreeCreateScript(global: t, project: p) == "")
    }
}
