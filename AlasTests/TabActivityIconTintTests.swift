import AppKit
import SwiftUI
import Testing
@testable import Alas

/// Verifies that tab width remains stable across all activity states now that
/// the separate activity dot has been replaced by tinting the terminal icon.
@Suite(.serialized)
@MainActor
struct TabActivityIconTintTests {
    private func currentTheme() -> Theme {
        try! ThemeStore().current
    }

    @Test func tabWidthIsStableAcrossActivityStates() {
        let tab = Tab.terminal(TerminalTabState(id: "t1", title: "bash", sessionId: "s1"))
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
        let withoutHarness = tabBarWidth(tab: tab, activityState: nil)
        let withHarness = tabBarWidth(tab: tab, activityState: .busy)
        #expect(withoutHarness == withHarness)
    }

    // MARK: - Helpers

    private func tabBarWidth(tab: Tab, activityState: ActivityState?) -> CGFloat {
        let lookup: (TabID) -> (agent: AgentKind, state: ActivityState)? = { _ in
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
            onRenameTerminal: { _ in },
            onNewTerminal: { },
            enabledAgents: [],
            onLaunchAgent: { _ in },
            onRevealRightSidebar: { },
            rightSidebarHidden: false,
            onMove: { _, _ in }
        )
        .environment(\.theme, currentTheme())

        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 34)
        controller.view.layoutSubtreeIfNeeded()
        return controller.view.fittingSize.width
    }
}
