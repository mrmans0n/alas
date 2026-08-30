import Testing
@testable import Alas

struct CenterTabCompositionTests {
    @Test func checkoutSharedTabsComposeWithFocusedMemberTabs() {
        let terminal = Tab.terminal(.init(id: "shared-terminal", title: "Terminal", sessionId: "terminal"))
        let acp = Tab.acpSession(.init(sessionId: "acp", title: "ACP"))
        let editor = Tab.editor(.init(id: "member-editor", title: "README.md", relativePath: "README.md"))

        let composition = CenterTabComposition(
            sharedTabs: [terminal, acp],
            focusedMemberTabs: [editor],
            activeSharedTabId: acp.id,
            activeFocusedMemberTabId: editor.id
        )

        #expect(composition.tabs.map(\.id) == [terminal.id, acp.id, editor.id])
        #expect(composition.activeId == acp.id)
    }

    @Test func focusChangeRestoresFocusedMemberActiveWhenNoSharedTabIsActive() {
        let firstEditor = Tab.editor(.init(id: "first", title: "first.md", relativePath: "first.md"))
        let secondEditor = Tab.editor(.init(id: "second", title: "second.md", relativePath: "second.md"))

        let composition = CenterTabComposition(
            sharedTabs: [],
            focusedMemberTabs: [secondEditor],
            activeSharedTabId: firstEditor.id,
            activeFocusedMemberTabId: secondEditor.id
        )

        #expect(composition.activeId == secondEditor.id)
    }

    @Test func focusChangeKeepsTheActiveSharedTabAheadOfTheNewMemberTabs() {
        let terminal = Tab.terminal(.init(id: "shared", title: "Terminal", sessionId: "terminal"))
        let nextMemberEditor = Tab.editor(.init(id: "next", title: "next.md", relativePath: "next.md"))

        let composition = CenterTabComposition(
            sharedTabs: [terminal],
            focusedMemberTabs: [nextMemberEditor],
            activeSharedTabId: terminal.id,
            activeFocusedMemberTabId: nextMemberEditor.id
        )

        #expect(composition.activeId == terminal.id)
        #expect(composition.tabs.map(\.id) == [terminal.id, nextMemberEditor.id])
    }
}
