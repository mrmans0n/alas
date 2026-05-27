import Testing
import SwiftUI
import AppKit
@testable import Alas

/// Smoke tests for touch-target sized controls to guard against frame or
/// label crashes when rendered in an NSHostingController.
@Suite(.serialized)
@MainActor
struct TouchTargetSmokeTests {
    private func currentTheme() -> Theme {
        try! ThemeStore().current
    }

    @Test func segmentedControlRendersWithoutCrashing() {
        let view = Seg(value: .constant(MarkdownViewMode.editor),
                       options: [(.editor, "Editor"), (.preview, "Preview")])
            .environment(\.theme, currentTheme())
        let controller = NSHostingController(rootView: view)
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.view != nil)
    }

    @Test func segmentedControlWithSystemImageRendersWithoutCrashing() {
        let view = Seg(value: .constant(MarkdownViewMode.editor),
                       systemImageOptions: [(.editor, "pencil"), (.preview, "eye")])
            .environment(\.theme, currentTheme())
        let controller = NSHostingController(rootView: view)
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.view != nil)
    }

    @Test func tabBarViewRendersWithoutCrashing() {
        let tab = Tab.editor(EditorTabState(
            id: "t1",
            title: "hello.swift",
            relativePath: "hello.swift",
            revealLine: nil,
            revealCharacter: nil,
            externalAbsolutePath: nil,
            originatingRelativePath: nil,
            markdownViewMode: nil,
            markdownSplitFraction: nil
        ))
        let view = TabBarView(
            tabs: [tab],
            activeId: tab.id,
            harnessLookup: { _ in nil },
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
            onLaunchACPSession: { _ in },
            acpAgents: [],
            onRevealRightSidebar: { },
            rightSidebarHidden: false,
            onRevealSidebar: { },
            sidebarHidden: false,
            onMove: { _, _ in },
            titleLookup: { _ in nil }
        )
        .environment(\.theme, currentTheme())
        let controller = NSHostingController(rootView: view)
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.view != nil)
    }

    @Test func tabBarViewWithDirtyAndHarnessRendersWithoutCrashing() {
        let tab = Tab.terminal(TerminalTabState(id: "term1", title: "bash", sessionId: "s1"))
        let view = TabBarView(
            tabs: [tab],
            activeId: tab.id,
            harnessLookup: { _ in (agent: .codex, state: .busy) },
            dirtyLookup: { _ in true },
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
            onLaunchACPSession: { _ in },
            acpAgents: [],
            onRevealRightSidebar: { },
            rightSidebarHidden: false,
            onRevealSidebar: { },
            sidebarHidden: false,
            onMove: { _, _ in },
            titleLookup: { _ in nil }
        )
        .environment(\.theme, currentTheme())
        let controller = NSHostingController(rootView: view)
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.view != nil)
    }

    @Test func tabBarViewWithRightSidebarRevealRendersWithoutCrashing() {
        let tab = Tab.editor(EditorTabState(
            id: "t1",
            title: "hello.swift",
            relativePath: "hello.swift",
            revealLine: nil,
            revealCharacter: nil,
            externalAbsolutePath: nil,
            originatingRelativePath: nil,
            markdownViewMode: nil,
            markdownSplitFraction: nil
        ))
        let view = TabBarView(
            tabs: [tab],
            activeId: tab.id,
            harnessLookup: { _ in nil },
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
            onLaunchACPSession: { _ in },
            acpAgents: [],
            onRevealRightSidebar: { },
            rightSidebarHidden: true,
            onRevealSidebar: { },
            sidebarHidden: false,
            onMove: { _, _ in },
            titleLookup: { _ in nil }
        )
        .environment(\.theme, currentTheme())
        let controller = NSHostingController(rootView: view)
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.view != nil)
    }

    @Test func tabBarViewWithSidebarRevealRendersWithoutCrashing() {
        let tab = Tab.editor(EditorTabState(
            id: "t1",
            title: "hello.swift",
            relativePath: "hello.swift",
            revealLine: nil,
            revealCharacter: nil,
            externalAbsolutePath: nil,
            originatingRelativePath: nil,
            markdownViewMode: nil,
            markdownSplitFraction: nil
        ))
        let view = TabBarView(
            tabs: [tab],
            activeId: tab.id,
            harnessLookup: { _ in nil },
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
            onLaunchACPSession: { _ in },
            acpAgents: [],
            onRevealRightSidebar: { },
            rightSidebarHidden: false,
            onRevealSidebar: { },
            sidebarHidden: true,
            onMove: { _, _ in },
            titleLookup: { _ in nil }
        )
        .environment(\.theme, currentTheme())
        let controller = NSHostingController(rootView: view)
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.view != nil)
    }

    @Test func stageChipRendersWithoutCrashing() {
        let view = StageChip(staged: false, action: { })
            .environment(\.theme, currentTheme())
        let controller = NSHostingController(rootView: view)
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.view != nil)
    }

    @Test func stageChipStagedRendersWithoutCrashing() {
        let view = StageChip(staged: true, action: { })
            .environment(\.theme, currentTheme())
        let controller = NSHostingController(rootView: view)
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.view != nil)
    }
}
