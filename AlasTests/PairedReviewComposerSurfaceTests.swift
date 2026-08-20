import AppKit
import SwiftUI
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct PairedReviewComposerSurfaceTests {
    @Test func reviewDraftQuoteUsesTheFileLanguageAndAConflictFreeFence() {
        #expect(ReviewDraftQuote.markdown(path: "Sources/App.swift", selectedText: "let value = 1") == """
        ```swift
        let value = 1
        ```
        """)
        #expect(ReviewDraftQuote.markdown(path: "README", selectedText: "contains ``` here") == """
        ````
        contains ``` here
        ````
        """)
    }

    @Test func reviewDraftComposerInsertsRequestedQuoteAtTheSelection() async throws {
        let quote = ReviewDraftQuote.markdown(path: "Sources/App.swift", selectedText: "let value = 1")
        let model = ReviewDraftComposerCapture(text: "beforeafter", quoteMarkdown: quote)
        let controller = NSHostingController(
            rootView: ReviewDraftComposerCaptureHarness(model: model, theme: try! ThemeStore().current)
        )
        let window = attach(controller)
        await drain(controller.view)

        let composer = try #require(textView(containing: model.text, in: controller.view))
        composer.setSelectedRange(NSRange(location: 6, length: 0))
        model.quoteInsertionGeneration += 1
        await drain(controller.view)

        #expect(model.text == "before\n\n\(quote)\n\nafter")
        window.orderOut(nil)
    }

    @Test func reviewDraftComposerWrapsSelectionAndRoutesKeyboardActions() async throws {
        let model = ReviewDraftComposerCapture(text: "review body")
        let controller = NSHostingController(
            rootView: ReviewDraftComposerCaptureHarness(model: model, theme: try! ThemeStore().current)
        )
        let window = attach(controller)
        await drain(controller.view)

        let composer = try #require(textView(containing: model.text, in: controller.view) as? PairedDelimiterTextView)
        composer.setSelectedRange(NSRange(location: 0, length: model.text.utf16.count))
        composer.performKeyboardTextInsertion {
            composer.insertText("`", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        #expect(model.text == "`review body`")

        composer.keyDown(with: try keyEvent(characters: "\r", modifiers: .command))
        composer.keyDown(with: try keyEvent(characters: "\u{1b}", modifiers: []))
        #expect(model.saveCount == 1)
        #expect(model.cancelCount == 1)

        window.orderOut(nil)
    }

    @Test func inlineReplyAndEditBindingsReceiveWrappedSelections() async throws {
        let model = InlineCommentCardCapture()
        let controller = NSHostingController(rootView: InlineCommentCardCaptureHarness(model: model))
        let window = attach(controller, height: 520)
        await drain(controller.view)

        let replyEditor = try #require(textView(containing: "reply body", in: controller.view))
        wrapSelection(in: replyEditor)
        #expect(model.replyState.replyDraft == "`reply body`")

        let editEditor = try #require(textView(containing: "edit body", in: controller.view))
        wrapSelection(in: editEditor)
        #expect(model.editState.editDraft == "`edit body`")

        window.orderOut(nil)
    }

    @Test func providerReplyBindingReceivesWrappedSelection() async throws {
        let model = ProviderReplyCapture()
        let controller = NSHostingController(rootView: ProviderReplyCaptureHarness(model: model))
        let window = attach(controller)
        await drain(controller.view)

        let editor = try #require(textView(containing: "provider reply", in: controller.view))
        wrapSelection(in: editor)
        #expect(model.editorState.body == "`provider reply`")

        window.orderOut(nil)
    }

    @Test func providerReplyEmptyEditorPreservesReplyLabelAndMinimumHeight() async throws {
        let model = ProviderReplyCapture(body: "")
        let controller = NSHostingController(rootView: ProviderReplyCaptureHarness(model: model))
        let window = attach(controller)
        await drain(controller.view)

        let replyEditor = try #require(firstEditableTextView(in: controller.view))
        let scrollView = try #require(replyEditor.enclosingScrollView)

        #expect(scrollView.frame.height >= 32)
        #expect(replyEditor.accessibilityPlaceholderValue() == "Reply")
        window.orderOut(nil)
    }

    @Test func verdictSummaryEditorWrapsSelectedText() async throws {
        let controller = NSHostingController(
            rootView: VerdictSheet(
                pendingCount: 1
            )
            .environment(\.theme, try! ThemeStore().current)
        )
        let window = attach(controller, height: 420)
        await drain(controller.view)

        let editor = try #require(firstEditableTextView(in: controller.view))
        editor.insertText("verdict summary", replacementRange: NSRange(location: NSNotFound, length: 0))
        wrapSelection(in: editor)

        #expect(editor.string == "`verdict summary`")
        window.orderOut(nil)
    }

    @Test func verdictSummaryRequestChangesRequiresNonEmptySummary() {
        #expect(!VerdictSheet.canSubmit(verdict: .requestChanges, summaryBody: ""))
        #expect(!VerdictSheet.canSubmit(verdict: .requestChanges, summaryBody: " \n\t "))
        #expect(VerdictSheet.canSubmit(verdict: .requestChanges, summaryBody: "needs work"))
        #expect(VerdictSheet.canSubmit(verdict: .comment, summaryBody: ""))
        #expect(VerdictSheet.canSubmit(verdict: .approve, summaryBody: ""))
    }

    @Test func providerPublishSummaryBindingReceivesWrappedSelectionAndPreservesDisabledState() async throws {
        let model = ProviderPublishCapture()
        let controller = NSHostingController(rootView: ProviderPublishCaptureHarness(model: model))
        let window = attach(controller, height: 420)
        await drain(controller.view)

        let editor = try #require(textView(containing: "publish summary", in: controller.view))
        #expect(editor.isEditable)
        wrapSelection(in: editor)
        #expect(model.summaryBody == "`publish summary`")

        model.isPublishing = true
        await drain(controller.view)
        #expect(!editor.isEditable)

        window.orderOut(nil)
    }

    @Test func draftSummaryEditingBindingReceivesWrappedSelection() async throws {
        let capture = DraftSummaryEditCapture(body: "draft summary")
        let controller = NSHostingController(rootView: DraftSummaryEditCaptureHarness(capture: capture))
        let window = attach(controller, height: 240)
        await drain(controller.view)

        let editor = try await waitForTextView(containing: "draft summary", in: controller.view)
        wrapSelection(in: editor)

        #expect(capture.body == "`draft summary`")
        window.orderOut(nil)
    }

    private func attach<Content: View>(
        _ controller: NSHostingController<Content>,
        height: CGFloat = 300
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: height),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func drain(_ view: NSView) async {
        for _ in 0..<4 {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.001))
            await Task.yield()
        }
    }

    private func textView(containing text: String, in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView, textView.string == text {
            return textView
        }
        for subview in view.subviews {
            if let match = textView(containing: text, in: subview) { return match }
        }
        return nil
    }

    private func firstEditableTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView, textView.isEditable {
            return textView
        }
        return view.subviews.lazy.compactMap(firstEditableTextView).first
    }

    private func wrapSelection(in textView: NSTextView) {
        textView.setSelectedRange(NSRange(location: 0, length: textView.string.utf16.count))
        if let pairedTextView = textView as? PairedDelimiterTextView {
            pairedTextView.performKeyboardTextInsertion {
                pairedTextView.insertText("`", replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        } else {
            textView.insertText("`", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }

    private func waitForTextView(containing text: String, in view: NSView) async throws -> NSTextView {
        for _ in 0..<20 {
            view.layoutSubtreeIfNeeded()
            if let textView = textView(containing: text, in: view) {
                return textView
            }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            await Task.yield()
        }
        return try #require(textView(containing: text, in: view))
    }

    private func keyEvent(characters: String, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: 0
        ))
    }
}

@MainActor
private final class ReviewDraftComposerCapture: ObservableObject {
    @Published var text: String
    @Published var quoteInsertionGeneration = 0
    let quoteMarkdown: String?
    var saveCount = 0
    var cancelCount = 0

    init(text: String, quoteMarkdown: String? = nil) {
        self.text = text
        self.quoteMarkdown = quoteMarkdown
    }
}

@MainActor
private struct ReviewDraftComposerCaptureHarness: View {
    @ObservedObject var model: ReviewDraftComposerCapture
    @FocusState private var isFocused: Bool
    let theme: Theme

    var body: some View {
        ReviewDraftComposerTextEditor(
            text: $model.text,
            theme: theme,
            isFocused: $isFocused,
            quoteMarkdown: model.quoteMarkdown,
            quoteInsertionGeneration: model.quoteInsertionGeneration,
            onSave: { model.saveCount += 1 },
            onCancel: { model.cancelCount += 1 }
        )
        .frame(height: 100)
    }
}

@MainActor
private final class InlineCommentCardCapture: ObservableObject {
    @Published var replyState = DiffInlineCommentCardEditorState(
        isComposerOpen: true,
        replyDraft: "reply body"
    )
    @Published var editState = DiffInlineCommentCardEditorState(
        editingCommentID: "comment-edit",
        editDraft: "edit body"
    )
}

@MainActor
private struct InlineCommentCardCaptureHarness: View {
    @ObservedObject var model: InlineCommentCardCapture

    private let thread = DiffInlineCommentThread(
        id: "thread",
        filePath: "Sources/App.swift",
        newLine: 7,
        isResolved: false,
        isOutdated: false,
        comments: [
            DiffInlineComment(
                id: "comment-edit",
                author: "reviewer",
                body: "original comment",
                viewerCanUpdate: true
            ),
        ]
    )

    var body: some View {
        VStack {
            DiffInlineCommentCard(thread: thread, editorState: $model.replyState)
            DiffInlineCommentCard(thread: thread, editorState: $model.editState)
        }
        .frame(width: 480)
    }
}

@MainActor
private final class ProviderReplyCapture: ObservableObject {
    @Published var editorState: DiffReviewInlineFeedbackReplyEditorState

    init(body: String = "provider reply") {
        editorState = DiffReviewInlineFeedbackReplyEditorState(
            isReplying: true,
            body: body
        )
    }
}

@MainActor
private struct ProviderReplyCaptureHarness: View {
    @ObservedObject var model: ProviderReplyCapture

    private let feedback = DiffReviewInlineFeedback(
        id: "provider-thread",
        providerName: "GitHub",
        author: "reviewer",
        bodyPreview: "Please revise this.",
        status: .actionable,
        providerURL: nil,
        anchor: DiffReviewInlineFeedbackAnchor(path: "Sources/App.swift", line: 7, side: .new),
        evidenceItemID: "provider-thread"
    )
    private let file = DiffReviewFileSummary(
        path: "Sources/App.swift",
        namespace: "github",
        groupID: nil,
        groupTitle: nil,
        status: .modified,
        additions: 1,
        deletions: 0,
        isRenderable: true
    )

    var body: some View {
        DiffReviewInlineFeedbackCard(
            item: feedback,
            file: file,
            isFocused: false,
            actions: DiffReviewInlineFeedbackActions(),
            onSelect: { _ in },
            replyEditorState: $model.editorState
        )
        .frame(width: 480)
        .environment(\.theme, try! ThemeStore().current)
    }
}

@MainActor
private final class ProviderPublishCapture: ObservableObject {
    @Published var selectedDecision = ProviderReviewDecision.requestChanges
    @Published var summaryBody = "publish summary"
    @Published var isPublishing = false
}

@MainActor
private struct ProviderPublishCaptureHarness: View {
    @ObservedObject var model: ProviderPublishCapture

    var body: some View {
        ProviderReviewPublishConfirmationView(
            providerName: "GitHub",
            reviewIdentity: "#42",
            commentCount: 1,
            unpublishableMessages: [],
            allowedDecisions: [.comment, .approve, .requestChanges],
            selectedDecision: $model.selectedDecision,
            summaryBody: $model.summaryBody,
            isPublishing: model.isPublishing,
            errorMessage: nil,
            onCancel: {},
            onConfirm: {}
        )
        .environment(\.theme, try! ThemeStore().current)
    }
}

@MainActor
private final class DraftSummaryEditCapture: ObservableObject {
    @Published var body: String

    init(body: String) {
        self.body = body
    }
}

@MainActor
private struct DraftSummaryEditCaptureHarness: View {
    @ObservedObject var capture: DraftSummaryEditCapture

    var body: some View {
        ReviewDraftSummaryCommentEditor(
            text: $capture.body,
            accessibilityIdentifier: "review-draft-summary-editor-draft-edit"
        )
        .environment(\.theme, try! ThemeStore().current)
    }
}
