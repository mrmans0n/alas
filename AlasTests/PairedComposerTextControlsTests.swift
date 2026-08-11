import AppKit
import Combine
import SwiftUI
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct PairedComposerTextControlsTests {
    @Test func wrapsPlainSelectionAndKeepsItSelected() {
        let textView = makePairedTextView(text: "value")
        textView.setSelectedRange(NSRange(location: 0, length: 5))

        textView.performKeyboardTextInsertion {
            textView.insertText("`", replacementRange: NSRange(location: NSNotFound, length: 0))
        }

        #expect(textView.string == "`value`")
        #expect(textView.selectedRange() == NSRange(location: 1, length: 5))
    }

    @Test func wrappingPreservesAttributedSelection() {
        let storage = NSTextStorage(attributedString: NSAttributedString(
            string: "value",
            attributes: [.toolTip: "keep-me"]
        ))
        let textView = makePairedTextView(storage: storage)
        textView.setSelectedRange(NSRange(location: 0, length: 5))

        textView.performKeyboardTextInsertion {
            textView.insertText("`", replacementRange: NSRange(location: NSNotFound, length: 0))
        }

        #expect(textView.string == "`value`")
        #expect(textView.textStorage?.attribute(.toolTip, at: 1, effectiveRange: nil) as? String == "keep-me")
        #expect(textView.selectedRange() == NSRange(location: 1, length: 5))
    }

    @Test func insertsEmptyPairAndStepsOverCloser() {
        let textView = makePairedTextView()

        textView.performKeyboardTextInsertion {
            textView.insertText("(", replacementRange: NSRange(location: NSNotFound, length: 0))
        }

        #expect(textView.string == "()")
        #expect(textView.selectedRange() == NSRange(location: 1, length: 0))

        textView.performKeyboardTextInsertion {
            textView.insertText(")", replacementRange: NSRange(location: NSNotFound, length: 0))
        }

        #expect(textView.string == "()")
        #expect(textView.selectedRange() == NSRange(location: 2, length: 0))
    }

    @Test func multiCharacterAndMarkedTextUseNativeInsertion() {
        let pastedTextView = makePairedTextView()

        pastedTextView.performKeyboardTextInsertion {
            pastedTextView.insertText("paste", replacementRange: NSRange(location: NSNotFound, length: 0))
        }

        #expect(pastedTextView.string == "paste")

        let markedTextView = makePairedTextView()
        markedTextView.setMarkedText(
            "candidate",
            selectedRange: NSRange(location: 9, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(markedTextView.hasMarkedText())

        markedTextView.performKeyboardTextInsertion {
            markedTextView.insertText("(", replacementRange: NSRange(location: NSNotFound, length: 0))
        }

        #expect(markedTextView.string == "(")
    }

    @Test func directSingleDelimiterInsertionBypassesPairing() {
        let dictationInsertion = makePairedTextView()

        dictationInsertion.insertText("(", replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(dictationInsertion.string == "(")
        #expect(dictationInsertion.selectedRange() == NSRange(location: 1, length: 0))
    }

    @Test func nativeTextInsertionBypassesSingleDelimiterPairing() {
        let emptyInsertion = makePairedTextView()
        emptyInsertion.performNativeTextInsertion {
            emptyInsertion.insertText("(", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        #expect(emptyInsertion.string == "(")
        #expect(emptyInsertion.selectedRange() == NSRange(location: 1, length: 0))

        let selectedInsertion = makePairedTextView(text: "value")
        selectedInsertion.setSelectedRange(NSRange(location: 0, length: 5))
        selectedInsertion.performNativeTextInsertion {
            selectedInsertion.insertText("`", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        #expect(selectedInsertion.string == "`")
        #expect(selectedInsertion.selectedRange() == NSRange(location: 1, length: 0))

        let pasteAndMatchStyleInsertion = makePairedTextView()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("(", forType: .string)
        defer { NSPasteboard.general.clearContents() }
        pasteAndMatchStyleInsertion.pasteAsPlainText(nil)
        #expect(pasteAndMatchStyleInsertion.string == "(")
        #expect(pasteAndMatchStyleInsertion.selectedRange() == NSRange(location: 1, length: 0))
    }

    @Test func pairedInsertionIsOneUndoableEdit() {
        let textView = makePairedTextView(text: "value")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = textView
        #expect(window.makeFirstResponder(textView))
        textView.allowsUndo = true
        textView.setSelectedRange(NSRange(location: 0, length: 5))

        textView.performKeyboardTextInsertion {
            textView.insertText("`", replacementRange: NSRange(location: NSNotFound, length: 0))
        }

        #expect(textView.string == "`value`")
        #expect(textView.undoManager?.canUndo == true)
        textView.undoManager?.undo()
        #expect(textView.string == "value")
    }

    @Test func textFieldSynchronizesBindingFocusAndSubmit() async throws {
        let model = ComposerControlModel(text: "value", isFocused: true)
        var submitCount = 0
        let controller = NSHostingController(rootView: PairedTextFieldHarness(model: model) {
            submitCount += 1
        })
        let window = attach(controller, size: NSSize(width: 360, height: 120))
        await drain(controller.view)

        let field = try #require(firstSubview(of: NSTextField.self, in: controller.view))
        let editor = try #require(window.fieldEditor(false, for: field) as? NSTextView)
        let coordinator = try #require(field.delegate as? PairedTextField.Coordinator)
        #expect(window.firstResponder === editor)
        editor.setSelectedRange(NSRange(location: 0, length: 5))

        let shouldUseNativeInsertion = coordinator.performKeyboardTextInsertion {
            coordinator.control(
                field,
                textView: editor,
                shouldChangeCharactersIn: NSRange(location: 0, length: 5),
                replacementString: "`"
            )
        }

        #expect(shouldUseNativeInsertion == false)
        #expect(field.stringValue == "`value`")
        #expect(model.text == "`value`")
        #expect(editor.selectedRange() == NSRange(location: 1, length: 5))
        #expect(editor.undoManager?.canUndo == true)

        editor.undoManager?.undo()
        await drain(controller.view)

        #expect(editor.string == "value")
        #expect(model.text == "value")

        field.sendAction(field.action, to: field.target)
        #expect(submitCount == 1)

        let sink = try #require(firstSubview(of: ComposerFocusSink.self, in: controller.view))
        #expect(window.makeFirstResponder(sink))
        await drain(controller.view)
        #expect(model.isFocused == false)

        model.isFocused = true
        await drain(controller.view)
        #expect(window.firstResponder === window.fieldEditor(false, for: field))

        await dismantle(model: model, controller: controller, window: window)
    }

    @Test func textFieldPasteBypassesSingleDelimiterPairing() async throws {
        let model = ComposerControlModel(text: "", isFocused: true)
        let controller = NSHostingController(rootView: PairedTextFieldHarness(model: model, onSubmit: {}))
        let window = attach(controller, size: NSSize(width: 360, height: 120))
        await drain(controller.view)

        let field = try #require(firstSubview(of: NSTextField.self, in: controller.view))
        let editor = try #require(window.fieldEditor(false, for: field) as? NSTextView)
        let coordinator = try #require(field.delegate as? PairedTextField.Coordinator)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("(", forType: .string)
        defer { NSPasteboard.general.clearContents() }

        #expect(coordinator.control(
            field,
            textView: editor,
            shouldChangeCharactersIn: NSRange(location: 0, length: 0),
            replacementString: "("
        ))

        #expect(coordinator.control(field, textView: editor, doCommandBy: #selector(NSText.paste(_:))))

        #expect(field.stringValue == "(")
        #expect(model.text == "(")
        #expect(editor.selectedRange() == NSRange(location: 1, length: 0))

        await dismantle(model: model, controller: controller, window: window)
    }

    @Test func textFieldDirectSingleDelimiterInsertionBypassesPairing() async throws {
        let model = ComposerControlModel(text: "", isFocused: true)
        let controller = NSHostingController(rootView: PairedTextFieldHarness(model: model, onSubmit: {}))
        let window = attach(controller, size: NSSize(width: 360, height: 120))
        await drain(controller.view)

        let field = try #require(firstSubview(of: NSTextField.self, in: controller.view))
        let editor = try #require(window.fieldEditor(false, for: field) as? NSTextView)
        let coordinator = try #require(field.delegate as? PairedTextField.Coordinator)

        #expect(coordinator.control(
            field,
            textView: editor,
            shouldChangeCharactersIn: NSRange(location: 0, length: 0),
            replacementString: "("
        ))

        editor.insertText("(", replacementRange: NSRange(location: NSNotFound, length: 0))
        await drain(controller.view)

        #expect(field.stringValue == "(")
        #expect(model.text == "(")
        #expect(editor.selectedRange() == NSRange(location: 1, length: 0))

        await dismantle(model: model, controller: controller, window: window)
    }

    @Test func textFieldPasteAndMatchStyleBypassesSingleDelimiterPairing() async throws {
        let model = ComposerControlModel(text: "", isFocused: true)
        let controller = NSHostingController(rootView: PairedTextFieldHarness(model: model, onSubmit: {}))
        let window = attach(controller, size: NSSize(width: 360, height: 120))
        await drain(controller.view)

        let field = try #require(firstSubview(of: NSTextField.self, in: controller.view))
        let editor = try #require(window.fieldEditor(false, for: field) as? NSTextView)
        let coordinator = try #require(field.delegate as? PairedTextField.Coordinator)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("(", forType: .string)
        defer { NSPasteboard.general.clearContents() }

        #expect(coordinator.control(
            field,
            textView: editor,
            doCommandBy: #selector(NSTextView.pasteAsPlainText(_:))
        ))

        #expect(field.stringValue == "(")
        #expect(model.text == "(")
        #expect(editor.selectedRange() == NSRange(location: 1, length: 0))

        await dismantle(model: model, controller: controller, window: window)
    }

    @Test func textEditorSynchronizesExternalConfigurationAndDisabledState() async throws {
        let model = ComposerControlModel(text: "start", isFocused: false)
        let controller = NSHostingController(rootView: PairedTextEditorHarness(model: model))
        let window = attach(controller, size: NSSize(width: 360, height: 180))
        await drain(controller.view)

        let textView = try #require(firstSubview(of: PairedDelimiterTextView.self, in: controller.view))
        let scrollView = try #require(textView.enclosingScrollView)
        #expect(textView.minSize.height >= scrollView.contentView.bounds.height)
        #expect(textView.frame.height >= scrollView.contentView.bounds.height)

        textView.setSelectedRange(NSRange(location: 5, length: 0))
        textView.performKeyboardTextInsertion {
            textView.insertText("{", replacementRange: NSRange(location: NSNotFound, length: 0))
        }

        #expect(model.text == "start{}")
        #expect(textView.textContainerInset == NSSize(width: 7, height: 9))

        model.text = "external"
        model.fontSize = 16
        model.textColor = .systemRed
        model.isEnabled = false
        await drain(controller.view)

        #expect(textView.string == "external")
        #expect(textView.font?.pointSize == 16)
        #expect(textView.textColor == .systemRed)
        #expect(textView.isEditable == false)
        #expect(textView.isSelectable == false)

        model.isEnabled = true
        model.isFocused = true
        await drain(controller.view)
        #expect(window.firstResponder === textView)

        let sink = try #require(firstSubview(of: ComposerFocusSink.self, in: controller.view))
        #expect(window.makeFirstResponder(sink))
        await drain(controller.view)
        #expect(model.isFocused == false)

        await dismantle(model: model, controller: controller, window: window)
    }

    @Test func textFieldUpdatesExternalConfigurationAndDisabledState() async throws {
        let model = ComposerControlModel(text: "initial", isFocused: false)
        let controller = NSHostingController(rootView: PairedTextFieldHarness(model: model, onSubmit: {}))
        let window = attach(controller, size: NSSize(width: 360, height: 120))
        await drain(controller.view)

        let field = try #require(firstSubview(of: NSTextField.self, in: controller.view))
        #expect(field.placeholderString == "Compose")

        model.text = "external"
        model.fontSize = 16
        model.textColor = .systemBlue
        model.isEnabled = false
        await drain(controller.view)

        #expect(field.stringValue == "external")
        #expect(field.font?.pointSize == 16)
        #expect(field.textColor == .systemBlue)
        #expect(field.isEnabled == false)

        await dismantle(model: model, controller: controller, window: window)
    }

    @Test func updatingInactiveFieldDoesNotTouchSiblingFieldEditor() async throws {
        let firstModel = ComposerControlModel(text: "alpha", isFocused: false)
        let secondModel = ComposerControlModel(text: "bravo", isFocused: true)
        let controller = NSHostingController(rootView: TwoPairedTextFieldsHarness(
            firstModel: firstModel,
            secondModel: secondModel
        ))
        let window = attach(controller, size: NSSize(width: 360, height: 120))
        await drain(controller.view)

        let fields = subviews(of: PairedTextFieldBackingView.self, in: controller.view)
        #expect(fields.count == 2)
        let firstField = try #require(fields.first { $0.stringValue == "alpha" })
        let secondField = try #require(fields.first { $0.stringValue == "bravo" })
        let secondEditor = try #require(secondField.currentEditor() as? NSTextView)
        #expect(window.firstResponder === secondEditor)
        secondEditor.setSelectedRange(NSRange(location: 1, length: 3))

        firstModel.text = "alpha updated"
        firstModel.fontSize = 17
        await drain(controller.view)

        #expect(firstField.stringValue == "alpha updated")
        #expect(secondField.currentEditor() === secondEditor)
        #expect(window.firstResponder === secondEditor)
        #expect(secondEditor.string == "bravo")
        #expect(secondEditor.selectedRange() == NSRange(location: 1, length: 3))
        #expect(secondModel.isFocused)

        firstModel.isPresented = false
        secondModel.isPresented = false
        await drain(controller.view)
        #expect(firstField.delegate == nil)
        #expect(secondField.delegate == nil)
        #expect(window.firstResponder !== secondEditor)
    }

    @Test func representablesDismantleWithoutRetainingHost() async throws {
        let model = ComposerControlModel(text: "lifecycle", isFocused: false)
        let controller = NSHostingController(rootView: PairedControlLifecycleHarness(model: model))
        await drain(controller.view)

        let field = try #require(firstSubview(of: PairedTextFieldBackingView.self, in: controller.view))
        let editor = try #require(firstSubview(of: PairedDelimiterTextView.self, in: controller.view))

        model.isPresented = false
        await drain(controller.view)

        #expect(field.delegate == nil)
        #expect(editor.delegate == nil)
        #expect(firstSubview(of: PairedTextFieldBackingView.self, in: controller.view) == nil)
        #expect(firstSubview(of: PairedDelimiterTextView.self, in: controller.view) == nil)
    }

    private func makePairedTextView(text: String = "") -> PairedDelimiterTextView {
        makePairedTextView(storage: NSTextStorage(string: text))
    }

    private func makePairedTextView(storage: NSTextStorage) -> PairedDelimiterTextView {
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 320, height: 120))
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        let textView = PairedDelimiterTextView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 120),
            textContainer: container
        )
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        return textView
    }

    private func attach<Content: View>(
        _ controller: NSHostingController<Content>,
        size: NSSize
    ) -> NSWindow {
        let frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        controller.view.frame = frame
        controller.view.layoutSubtreeIfNeeded()
        return window
    }

    private func dismantle<Content: View>(
        model: ComposerControlModel,
        controller: NSHostingController<Content>,
        window: NSWindow
    ) async {
        model.isPresented = false
        await drain(controller.view)
        #expect(firstSubview(of: PairedTextFieldBackingView.self, in: controller.view) == nil)
        #expect(firstSubview(of: PairedDelimiterTextView.self, in: controller.view) == nil)
        withExtendedLifetime(window) {}
    }

    private func drain(_ view: NSView) async {
        for _ in 0..<12 {
            view.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 1_000_000)
            await Task.yield()
        }
    }

    private func firstSubview<T: NSView>(of type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = firstSubview(of: type, in: subview) { return match }
        }
        return nil
    }

    private func subviews<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        var matches = view.subviews.compactMap { $0 as? T }
        matches.append(contentsOf: view.subviews.flatMap { subviews(of: type, in: $0) })
        return matches
    }
}

@MainActor
private final class ComposerControlModel: ObservableObject {
    @Published var text: String
    @Published var isFocused: Bool
    @Published var isEnabled = true
    @Published var fontSize: CGFloat = 13
    @Published var textColor = NSColor.labelColor
    @Published var isPresented = true

    init(text: String, isFocused: Bool) {
        self.text = text
        self.isFocused = isFocused
    }
}

@MainActor
private struct PairedTextFieldHarness: View {
    @ObservedObject var model: ComposerControlModel
    let onSubmit: () -> Void

    var body: some View {
        VStack {
            if model.isPresented {
                PairedTextField(
                    text: $model.text,
                    placeholder: "Compose",
                    font: .systemFont(ofSize: model.fontSize),
                    textColor: model.textColor,
                    isEnabled: model.isEnabled,
                    isFocused: $model.isFocused,
                    onSubmit: onSubmit
                )
                .frame(height: 28)
            }
            ComposerFocusSinkRepresentable()
        }
    }
}

@MainActor
private struct PairedTextEditorHarness: View {
    @ObservedObject var model: ComposerControlModel

    var body: some View {
        VStack {
            if model.isPresented {
                PairedTextEditor(
                    text: $model.text,
                    font: .systemFont(ofSize: model.fontSize),
                    textColor: model.textColor,
                    isEnabled: model.isEnabled,
                    isFocused: $model.isFocused,
                    textContainerInset: NSSize(width: 7, height: 9)
                )
                .frame(height: 100)
            }
            ComposerFocusSinkRepresentable()
        }
    }
}

@MainActor
private struct TwoPairedTextFieldsHarness: View {
    let firstModel: ComposerControlModel
    let secondModel: ComposerControlModel

    var body: some View {
        VStack {
            PairedTextFieldLeaf(model: firstModel)
            PairedTextFieldLeaf(model: secondModel)
        }
    }
}

@MainActor
private struct PairedControlLifecycleHarness: View {
    @ObservedObject var model: ComposerControlModel

    var body: some View {
        if model.isPresented {
            VStack {
                PairedTextField(text: $model.text)
                PairedTextEditor(text: $model.text)
            }
        }
    }
}

@MainActor
private struct PairedTextFieldLeaf: View {
    @ObservedObject var model: ComposerControlModel

    var body: some View {
        if model.isPresented {
            PairedTextField(
                text: $model.text,
                font: .systemFont(ofSize: model.fontSize),
                textColor: model.textColor,
                isEnabled: model.isEnabled,
                isFocused: $model.isFocused
            )
            .frame(height: 28)
        }
    }
}

private struct ComposerFocusSinkRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> ComposerFocusSink {
        ComposerFocusSink(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
    }

    func updateNSView(_ nsView: ComposerFocusSink, context: Context) {}
}

private final class ComposerFocusSink: NSView {
    override var acceptsFirstResponder: Bool { true }
}
