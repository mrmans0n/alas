import Testing
@testable import Alas

struct TabIsTerminalTests {
    @Test func terminalTabReportsIsTerminal() {
        let tab = Tab.terminal(TerminalTabState(id: "t1", title: "bash", sessionId: "s1"))
        #expect(tab.isTerminal)
    }

    @Test func editorTabDoesNotReportIsTerminal() {
        let tab = Tab.editor(EditorTabState(
            id: "e1",
            title: "hello.swift",
            relativePath: "hello.swift",
            revealLine: nil,
            revealCharacter: nil,
            externalAbsolutePath: nil,
            originatingRelativePath: nil,
            markdownViewMode: nil,
            markdownSplitFraction: nil
        ))
        #expect(!tab.isTerminal)
    }

    @Test func commitTabDoesNotReportIsTerminal() {
        let tab = Tab.commit(CommitTabState(worktreeId: "wt", sha: "abc", title: "fix"))
        #expect(!tab.isTerminal)
    }
}
