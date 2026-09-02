import AppKit
import SwiftUI
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct PairedPrimaryComposerSurfaceTests {
    @Test func reviewRequestTitleAndBodyUsePairedBindings() async throws {
        let model = ReviewRequestComposerModel(title: "Review title", body: "Review body")
        let controller = NSHostingController(rootView: ReviewRequestComposerHarness(model: model, theme: try! ThemeStore().current))
        let window = attach(controller)
        defer { window.orderOut(nil) }
        await drain(controller.view)

        let title = try #require(firstSubview(of: PairedTextFieldBackingView.self, in: controller.view))
        #expect(window.makeFirstResponder(title))
        let titleEditor = try #require(title.currentEditor() as? PairedDelimiterTextView)
        titleEditor.setSelectedRange(NSRange(location: 0, length: model.title.utf16.count))
        titleEditor.performKeyboardTextInsertion {
            titleEditor.insertText("`", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        await drain(controller.view)
        #expect(model.title == "`Review title`")

        let body = try #require(firstSubview(of: PairedDelimiterTextView.self, in: controller.view))
        body.setSelectedRange(NSRange(location: 0, length: model.body.utf16.count))
        body.performKeyboardTextInsertion {
            body.insertText("`", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        #expect(model.body == "`Review body`")
    }

    @Test func ggSplitCardInvokesDraftChangeAfterPairedEdit() async throws {
        let service = GGSplitSurfaceService()
        let model = GGSplitCommitModel(
            service: service,
            target: GGSplitCommitTarget(worktreeId: "wt", targetGGID: "change-2", targetSHA: "abc123"),
            capabilities: GGCapabilities(structuredSplit: true, keepCurrentUnstack: true),
            workflowAvailable: true
        )
        try await model.load()
        var draftChanges: [String] = []
        let controller = NSHostingController(rootView: GGSplitCommitTabView(
            tabState: GGSplitCommitTabState(worktreeId: "wt", targetGGID: "change-2", targetSHA: "abc123"),
            worktreePath: URL(fileURLWithPath: "/tmp"),
            capabilities: GGCapabilities(structuredSplit: true, keepCurrentUnstack: true),
            workflowAvailable: true,
            hasBlockingGitOperation: false,
            model: model,
            codeFontFamily: "Menlo",
            codeFontSize: 12,
            onCancel: {},
            onDraftChange: { draft in draftChanges.append(draft.firstMessage) }
        )
        .environment(\.theme, try! ThemeStore().current))
        let window = attach(controller)
        defer { window.orderOut(nil) }
        await drain(controller.view)
        await drain(controller.view)
        draftChanges.removeAll()

        let field = try #require(firstSubview(of: PairedTextFieldBackingView.self, in: controller.view))
        #expect(field.focusRingType == .default)
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? PairedDelimiterTextView)
        editor.setSelectedRange(NSRange(location: 0, length: 12))
        editor.performKeyboardTextInsertion {
            editor.insertText("`", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        await drain(controller.view)

        #expect(model.firstMessage == "`First commit`")
        #expect(draftChanges == ["`First commit`"])
    }

    private func attach<Content: View>(_ controller: NSHostingController<Content>) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func drain(_ view: NSView) async {
        view.layoutSubtreeIfNeeded()
        await Task.yield()
        view.layoutSubtreeIfNeeded()
    }

    private func firstSubview<T: NSView>(of type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = firstSubview(of: type, in: subview) { return match }
        }
        return nil
    }
}

@MainActor
private final class ReviewRequestComposerModel: ObservableObject {
    @Published var title: String
    @Published var body: String

    init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

@MainActor
private struct ReviewRequestComposerHarness: View {
    @ObservedObject var model: ReviewRequestComposerModel
    let theme: Theme

    var body: some View {
        ReviewRequestMessageEditor(
            title: $model.title,
            bodyText: $model.body,
            aiToolId: .constant(""),
            editorTitle: "GitHub Pull Request",
            busy: false,
            error: nil,
            availableAgents: [],
            onGenerate: {},
            primaryAction: CommitPrimaryAction(label: "Create Pull Request", isEnabled: true, handler: {}),
            editorDisabled: false,
            onDismissError: {},
            accessory: nil
        )
        .environment(\.theme, theme)
    }
}

@MainActor
private final class GGSplitSurfaceService: GGSplitCommitServicing {
    private let description = GGSplitDescription(
        version: 1,
        planToken: "split-v1-token",
        target: GGSplitTargetIdentity(ggID: "change-2", sha: "abc123", tree: "tree123"),
        hunks: [GGSplitHunk(id: "h-1", path: "Sources/A.swift", header: "@@ -1 +1 @@", patch: "-old\n+new\n")],
        nonTextualFiles: [],
        firstMessage: "First commit",
        remainderMessage: "Remainder commit"
    )

    func loadDescription(target: GGSplitCommitTarget) async throws -> GGSplitLoadedDescription {
        GGSplitLoadedDescription(
            description: description,
            stackIdentity: GGStackIdentity(stackName: "stack", base: "main", headSHA: "head", operationID: nil)
        )
    }

    func applySplit(
        planURL: URL,
        target: GGSplitTargetIdentity,
        planToken: String,
        confirmedAgainst identity: GGStackIdentity
    ) async throws {}
}
