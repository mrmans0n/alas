import Testing
@testable import Alas

struct CloseTabConfirmationPolicyTests {
    @Test func terminalTabsRequireConfirmationOnlyWhenTerminalSettingIsEnabled() {
        var config = AppConfig.defaults
        let tab = Tab.terminal(TerminalTabState(id: "terminal-tab", title: "Terminal", sessionId: "session"))

        #expect(CloseTabConfirmationPolicy.prompt(for: tab, config: config) == nil)

        config.terminal.confirmCloseTabs = true
        #expect(CloseTabConfirmationPolicy.prompt(for: tab, config: config) == .terminal)
    }

    @Test func chatTabsRequireConfirmationOnlyWhenChatSettingIsEnabled() {
        var config = AppConfig.defaults
        let tab = Tab.acpSession(ACPSessionTabState(sessionId: "chat-session", title: "Chat"))

        #expect(CloseTabConfirmationPolicy.prompt(for: tab, config: config) == nil)

        config.harness.confirmCloseChatTabs = true
        #expect(CloseTabConfirmationPolicy.prompt(for: tab, config: config) == .chat)
    }

    @Test func otherTabTypesNeverRequireCloseConfirmation() {
        var config = AppConfig.defaults
        config.terminal.confirmCloseTabs = true
        config.harness.confirmCloseChatTabs = true

        let editor = Tab.editor(EditorTabState(id: "editor", title: "README.md", relativePath: "README.md"))
        let diff = Tab.diff(DiffTabState(id: "diff", title: "Diff", relativePath: "README.md"))

        #expect(CloseTabConfirmationPolicy.prompt(for: editor, config: config) == nil)
        #expect(CloseTabConfirmationPolicy.prompt(for: diff, config: config) == nil)
    }

    @Test func promptCopyMatchesTabKind() {
        #expect(CloseTabConfirmationPolicy.Prompt.terminal.title == "Close terminal tab?")
        #expect(CloseTabConfirmationPolicy.Prompt.terminal.confirmButtonTitle == "Close Terminal")
        #expect(CloseTabConfirmationPolicy.Prompt.chat.title == "Close chat tab?")
        #expect(CloseTabConfirmationPolicy.Prompt.chat.confirmButtonTitle == "Close Chat")
    }
}
