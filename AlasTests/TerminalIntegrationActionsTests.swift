import Testing

@testable import Alas

@Suite("TerminalIntegrationActions")
struct TerminalIntegrationActionsTests {
    @Test("not installed integrations show install only")
    func notInstalledActions() {
        #expect(TerminalIntegrationActions.actions(for: .notInstalled) == [
            TerminalIntegrationAction(kind: .install, title: "Install")
        ])
    }

    @Test("outdated integrations show update only")
    func outdatedActions() {
        #expect(TerminalIntegrationActions.actions(for: .outdated) == [
            TerminalIntegrationAction(kind: .install, title: "Update")
        ])
    }

    @Test("installed integrations show uninstall only")
    func installedActions() {
        #expect(TerminalIntegrationActions.actions(for: .installed) == [
            TerminalIntegrationAction(kind: .uninstall, title: "Uninstall")
        ])
    }
}
