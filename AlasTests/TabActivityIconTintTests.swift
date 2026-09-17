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
            tabButtonWidth(tab: tab, activityState: state)
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
        let withoutHarness = tabButtonWidth(tab: tab, activityState: nil)
        let withHarness = tabButtonWidth(tab: tab, activityState: .busy)
        #expect(withoutHarness == withHarness)
    }

    @Test func acpTabAddsAgentLogoWhenAgentIsResolved() {
        let tab = AppTab.acpSession(ACPSessionTabState(sessionId: "session-1", title: "Plan"))
        let withoutAgent = tabButtonWidth(tab: tab, activityState: nil)
        let withAgent = tabButtonWidth(
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
        let withoutAgent = tabButtonWidth(tab: tab, activityState: nil)
        let withAgent = tabButtonWidth(
            tab: tab,
            activityState: nil,
            acpAgentLookup: { _ in AgentBuiltins.entry(id: "codex") }
        )
        #expect(withAgent == withoutAgent)
    }

    // MARK: - Helpers

    private func tabButtonWidth(
        tab: AppTab,
        activityState: ActivityState?,
        acpAgentLookup: @escaping (AppTabID) -> AgentDefinition? = { _ in nil }
    ) -> CGFloat {
        let harnessInfo = activityState.map { (agent: AgentKind.codex, state: $0) }
        let view = TabButton(
            titleLookup: { _ in nil },
            tab: tab,
            active: true,
            showClose: true,
            harnessInfo: harnessInfo,
            dirtyLookup: { false },
            transcript: nil,
            acpAgent: acpAgentLookup(tab.id),
            onActivate: {},
            onClose: {}
        )
        .environment(\.theme, currentTheme())

        let controller = NSHostingController(rootView: view)
        controller.view.frame.size.height = 34
        controller.view.layoutSubtreeIfNeeded()
        return controller.view.fittingSize.width
    }
}
