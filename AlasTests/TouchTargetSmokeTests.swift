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

    @Test func alasSegmentedControlRendersEnabledAndDisabledOptions() {
        enum Choice: Hashable { case keep, close }
        let view = AlasSegmentedControl(
            selection: Choice.keep,
            options: [
                AlasSegmentedOption(id: .keep, label: "Keep pane open"),
                AlasSegmentedOption(
                    id: .close,
                    label: "Close pane",
                    isEnabled: false,
                    disabledHelp: "Unavailable"
                ),
            ],
            onSelect: { _ in }
        )
        .environment(\.theme, currentTheme())

        let controller = NSHostingController(rootView: view)
        controller.view.layoutSubtreeIfNeeded()

        #expect(controller.view.fittingSize.width > 0)
        #expect(controller.view.fittingSize.height > 0)
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
            transcriptLookup: { _ in nil }
        )
        .environment(\.theme, currentTheme())
        let controller = NSHostingController(rootView: view)
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.view != nil)
    }

    @Test func tabBarViewHostsOverflowingTabsInMarkedScrollView() {
        let tabs = (1...12).map { index in
            Tab.editor(EditorTabState(
                id: "t\(index)",
                title: "VeryLongFileName\(index).swift",
                relativePath: "Sources/VeryLongFileName\(index).swift",
                revealLine: nil,
                revealCharacter: nil,
                externalAbsolutePath: nil,
                originatingRelativePath: nil,
                markdownViewMode: nil,
                markdownSplitFraction: nil
            ))
        }
        let view = TabBarView(
            tabs: tabs,
            activeId: tabs.first?.id,
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
            transcriptLookup: { _ in nil }
        )
        .environment(\.theme, currentTheme())
        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 520, height: 34)
        controller.view.layoutSubtreeIfNeeded()

        #expect(allSubviews(of: controller.view).contains {
            $0.accessibilityIdentifier() == "tab-overflow-scroll"
        })
    }

    @Test func agentMenuSectionTitlesUseCurrentLabels() {
        #expect(TabBarView.terminalAgentMenuSectionTitle == "Terminal")
        #expect(TabBarView.acpAgentMenuSectionTitle == "ACP Chat")
    }

    @Test func tabBarViewWithAgentMenuSectionsRendersWithoutCrashing() throws {
        let tab = Tab.terminal(TerminalTabState(id: "term1", title: "bash", sessionId: "s1"))
        let terminalAgent = try #require(AgentBuiltins.entry(id: "codex"))
        let acpAgent = try #require(AgentBuiltins.entry(id: "claude"))
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
            onOpenWithSystem: { _ in },
            onRevealInFinder: { _ in },
            onRenameTerminal: { _ in },
            onRenameACPSession: { _ in },
            onCopyACPSession: { _ in },
            onExportACPSession: { _ in },
            onNewTerminal: { },
            enabledAgents: [terminalAgent],
            onLaunchAgent: { _ in },
            onLaunchACPSession: { _ in },
            acpAgents: [acpAgent],
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
            transcriptLookup: { _ in nil }
        )
        .environment(\.theme, currentTheme())
        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 34)
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.view.fittingSize.height > 0)
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
            transcriptLookup: { _ in nil }
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
            rightSidebarHidden: true,
            onRevealSidebar: { },
            sidebarHidden: false,
            onMove: { _, _ in },
            titleLookup: { _ in nil },
            transcriptLookup: { _ in nil }
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
            sidebarHidden: true,
            onMove: { _, _ in },
            titleLookup: { _ in nil },
            transcriptLookup: { _ in nil }
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

    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
    }
}
