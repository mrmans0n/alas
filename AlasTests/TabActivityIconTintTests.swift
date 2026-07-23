import AppKit
import SwiftUI
import Testing
@testable import Alas

/// Verifies that tab width remains stable across all activity states now that
/// the separate activity dot has been replaced by tinting the terminal icon.
@Suite(.serialized)
@MainActor
struct TabActivityIconTintTests {
    private typealias AppTab = Alas.Tab
    private typealias AppTabID = Alas.TabID

    private func currentTheme() -> Theme {
        try! ThemeStore().current
    }

    @Test func tabWidthIsStableAcrossActivityStates() {
        let tab = AppTab.terminal(TerminalTabState(id: "t1", title: "bash", sessionId: "s1"))
        let states: [ActivityState?] = [nil, .idle, .busy, .awaitingInput, .permissionRequest]
        let widths = states.map { state in
            tabBarWidth(tab: tab, activityState: state)
        }
        // All widths must be identical — no layout shift from activity state changes.
        for width in widths {
            #expect(width == widths[0])
        }
    }

    @Test func editorTabWidthIsStableWithAndWithoutHarness() {
        let tab = AppTab.editor(EditorTabState(
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
        let withoutHarness = tabBarWidth(tab: tab, activityState: nil)
        let withHarness = tabBarWidth(tab: tab, activityState: .busy)
        #expect(withoutHarness == withHarness)
    }

    @Test func acpTabAddsAgentLogoWhenAgentIsResolved() {
        let tab = AppTab.acpSession(ACPSessionTabState(sessionId: "session-1", title: "Plan"))
        let withoutAgent = tabBarWidth(tab: tab, activityState: nil)
        let withAgent = tabBarWidth(
            tab: tab,
            activityState: nil,
            acpAgentLookup: { _ in AgentBuiltins.entry(id: "codex") }
        )
        #expect(withAgent > withoutAgent)
    }

    @Test func nonAcpTabIgnoresAcpAgentLookup() {
        let tab = AppTab.editor(EditorTabState(
            id: "e2",
            title: "hello.swift",
            relativePath: "hello.swift",
            revealLine: nil,
            revealCharacter: nil,
            externalAbsolutePath: nil,
            originatingRelativePath: nil,
            markdownViewMode: nil,
            markdownSplitFraction: nil
        ))
        let withoutAgent = tabBarWidth(tab: tab, activityState: nil)
        let withAgent = tabBarWidth(
            tab: tab,
            activityState: nil,
            acpAgentLookup: { _ in AgentBuiltins.entry(id: "codex") }
        )
        #expect(withAgent == withoutAgent)
    }

    // MARK: - Helpers

    private func tabBarWidth(
        tab: AppTab,
        activityState: ActivityState?,
        acpAgentLookup: @escaping (AppTabID) -> AgentDefinition? = { _ in nil }
    ) -> CGFloat {
        let lookup: (AppTabID) -> (agent: AgentKind, state: ActivityState)? = { _ in
            guard let state = activityState else { return nil }
            return (agent: .codex, state: state)
        }
        let view = TabBarView(
            tabs: [tab],
            activeId: tab.id,
            harnessLookup: lookup,
            dirtyLookup: { _ in false },
            onActivate: { _ in },
            onClose: { _ in },
            onCloseOthers: { _ in },
            onCloseAll: { },
            onCloseToLeft: { _ in },
            onCloseToRight: { _ in },
            onCopyPath: { _ in },
            onCopyRelativePath: { _ in },
            onOpenWithSystem: { _ in },
            onRevealInFinder: { _ in },
            onRenameTerminal: { _ in },
            onRenameACPSession: { _ in },
            onCopyACPSession: { _ in },
            onExportACPSession: { _ in },
            onNewTerminal: { },
            enabledAgents: [],
            onLaunchAgent: { _ in },
            onLaunchACPSession: { _ in },
            acpAgents: [],
            loadRunScripts: { [] },
            isScriptRunning: { _ in false },
            onRunScript: { _ in },
            onRestartScript: { _ in },
            onNewRunScript: { _ in },
            onEditScripts: { },
            onRevealRightSidebar: { },
            rightSidebarHidden: false,
            onRevealSidebar: { },
            sidebarHidden: false,
            onMove: { _, _ in },
            titleLookup: { _ in nil },
            transcriptLookup: { _ in nil },
            acpAgentLookup: acpAgentLookup
        )
        .environment(\.theme, currentTheme())

        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 34)
        controller.view.layoutSubtreeIfNeeded()
        return controller.view.fittingSize.width
    }
}
