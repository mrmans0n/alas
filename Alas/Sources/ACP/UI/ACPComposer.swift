import SwiftUI
import AppKit

typealias ACPComposerSubmitCompletion = @MainActor (_ succeeded: Bool) -> Void
typealias ACPComposerSubmitHandler = (
    _ text: String,
    _ attachments: [ACPMessage.Attachment],
    _ draft: ACPComposerDraft,
    _ completion: @escaping ACPComposerSubmitCompletion
) -> Bool

struct ACPInputField: NSViewRepresentable {
    @ObservedObject var session: ACPSession
    let worktreeRoot: URL
    let actions: ACPComposerActions
    /// Persists the current composer draft after text storage changes.
    let onDraftChange: (ACPComposerDraft) -> Void
    /// Clears the persisted draft after an accepted submission.
    let onDraftClear: () -> Void
    /// Returns `true` when the host accepted the submission (and the
    /// textview should be cleared) or `false` to keep the draft in
    /// place (e.g. session not ready, prompt already in flight).
    let onSubmit: ACPComposerSubmitHandler

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ACPNSTextView()
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.isRichText = true
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.focusRingType = .none
        textView.textColor = NSColor(named: "fg") ?? NSColor.labelColor
        textView.insertionPointColor = NSColor.controlAccentColor
        context.coordinator.textView = textView
        context.coordinator.restoreInitialDraft(into: textView)
        // Publish the submit closure so the SwiftUI send button can fire
        // the same code path as ⏎.
        let coord = context.coordinator
        actions.submit = { [weak coord] in
            guard let coord, let tv = coord.textView else { return }
            coord.submit(tv)
        }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.focusRingType = .none
        scroll.documentView = textView
        // Auto-focus on mount. Tabs are created lazily (the switch in
        // `CenterPaneView` only renders the active tab), so this fires
        // every time the user swaps to this ACP tab.
        DispatchQueue.main.async { [weak textView] in
            guard let textView, let window = textView.window else { return }
            window.makeFirstResponder(textView)
        }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.promptSuggestions = session.promptSuggestions
        context.coordinator.theme = context.environment.theme
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            worktreeRoot: worktreeRoot,
            initialDraft: session.composerDraft,
            onDraftChange: onDraftChange,
            onDraftClear: onDraftClear,
            onSubmit: onSubmit
        )
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let worktreeRoot: URL
        let initialDraft: ACPComposerDraft
        let onDraftChange: (ACPComposerDraft) -> Void
        let onDraftClear: () -> Void
        let onSubmit: ACPComposerSubmitHandler
        var promptSuggestions: [ACPPromptSuggestion] = []
        /// Snapshotted at makeNSView time so the AppKit-only slash panel
        /// can render its SwiftUI content with our theme tokens.
        var theme: Theme?
        weak var textView: NSTextView?
        private var restoringDraft = false

        init(
            worktreeRoot: URL,
            initialDraft: ACPComposerDraft,
            onDraftChange: @escaping (ACPComposerDraft) -> Void,
            onDraftClear: @escaping () -> Void,
            onSubmit: @escaping ACPComposerSubmitHandler
        ) {
            self.worktreeRoot = worktreeRoot
            self.initialDraft = initialDraft
            self.onDraftChange = onDraftChange
            self.onDraftClear = onDraftClear
            self.onSubmit = onSubmit
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // Belt-and-suspenders Esc handling. keyDown already catches
            // keyCode 53 to close the slash panel, but NSTextView also
            // routes Esc through `cancelOperation:` after the input
            // method system gets a crack at it. If the panel is still
            // open here, close it and swallow the event.
            if selector == #selector(NSResponder.cancelOperation(_:)),
               let tv = textView as? ACPNSTextView,
               tv.isSlashPanelOpen {
                tv.dismissSlashPanel()
                return true
            }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                let event = NSApp.currentEvent
                let shift = event?.modifierFlags.contains(.shift) == true
                if shift {
                    textView.insertText("\n", replacementRange: textView.selectedRange())
                    return true
                }
                submit(textView)
                return true
            }
            return false
        }

        /// Re-apply markdown styling to the whole storage on every edit.
        /// Bold `**…**`, italic `*…*` / `_…_`, inline `` `…` ``. Block-level
        /// (#/```) is handled on the receiving side via ACPMarkdownText.
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView,
                  let storage = tv.textStorage
            else { return }
            ACPMarkdownLiveStyler.restyle(storage)
            guard !restoringDraft else { return }
            onDraftChange(Self.draft(from: storage))
        }

        func submit(_ textView: NSTextView) {
            let attributed = textView.attributedString()
            let (text, attachments) = Self.extract(attributed)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let draft = Self.draft(from: attributed)
            // Rejected submits keep the editable draft in place. Accepted
            // submits clear only the visible text view here; persisted
            // draft deletion waits for the async prompt completion.
            if onSubmit(text, attachments, draft, { [weak self, weak textView] succeeded in
                guard let self else { return }
                if succeeded {
                    self.onDraftClear()
                } else {
                    self.onDraftChange(draft)
                    if let textView {
                        self.restore(draft, into: textView)
                    }
                }
            }) {
                clearVisibleDraft(in: textView)
            }
        }

        func restoreInitialDraft(into textView: NSTextView) {
            guard !initialDraft.isEmpty else { return }
            restore(initialDraft, into: textView)
        }

        private func restore(_ draft: ACPComposerDraft, into textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            restoringDraft = true
            storage.setAttributedString(Self.attributedString(from: draft))
            ACPMarkdownLiveStyler.restyle(storage)
            textView.needsDisplay = true
            restoringDraft = false
        }

        private func clearVisibleDraft(in textView: NSTextView) {
            restoringDraft = true
            textView.string = ""
            textView.needsDisplay = true
            restoringDraft = false
        }

        static func draft(from attributed: NSAttributedString) -> ACPComposerDraft {
            var segments: [ACPComposerDraft.Segment] = []
            attributed.enumerateAttribute(
                .attachmentURI,
                in: NSRange(location: 0, length: attributed.length)
            ) { value, range, _ in
                if let uri = value as? String,
                   let chip = attributed.attribute(.attachment, at: range.location, effectiveRange: nil)
                            as? ACPMentionChipAttachment {
                    segments.append(.mention(displayName: chip.displayName, uri: uri))
                } else if let uri = value as? String {
                    let segment = attributed.attributedSubstring(from: range).string
                    let displayName = segment.trimmingCharacters(in: .init(charactersIn: "@ "))
                    segments.append(.mention(displayName: displayName, uri: uri))
                } else {
                    let text = attributed.attributedSubstring(from: range).string
                    if !text.isEmpty {
                        segments.append(.text(text))
                    }
                }
            }
            return ACPComposerDraft(segments: segments)
        }

        static func attributedString(from draft: ACPComposerDraft) -> NSAttributedString {
            let result = NSMutableAttributedString(string: "")
            let baseAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor,
            ]
            for segment in draft.segments {
                switch segment {
                case .text(let text):
                    result.append(NSAttributedString(string: text, attributes: baseAttributes))
                case .mention(let displayName, let uri):
                    let attachment = ACPMentionChipAttachment(displayName: displayName, uri: uri)
                    let chip = NSMutableAttributedString(attachment: attachment)
                    chip.addAttributes([
                        .attachmentURI: uri,
                        .toolTip: URL(string: uri)?.path ?? uri,
                    ], range: NSRange(location: 0, length: chip.length))
                    result.append(chip)
                }
            }
            return result
        }

        /// Walks the attributed string. Mention chips (attachments tagged
        /// with `attachmentURI`) become resource_link attachments and emit
        /// `@filename` in the text. Everything else is concatenated as-is —
        /// the user's markdown markers (`**bold**`, `# heading`, etc.) are
        /// preserved verbatim for the receiving agent.
        static func extract(_ attributed: NSAttributedString) -> (String, [ACPMessage.Attachment]) {
            var text = ""
            var atts: [ACPMessage.Attachment] = []
            attributed.enumerateAttribute(
                .attachmentURI,
                in: NSRange(location: 0, length: attributed.length)
            ) { value, range, _ in
                if let uri = value as? String,
                   let chip = attributed.attribute(.attachment, at: range.location, effectiveRange: nil)
                            as? ACPMentionChipAttachment {
                    text += "@" + chip.displayName + " "
                    atts.append(.init(uri: uri, name: chip.displayName))
                } else if let uri = value as? String {
                    // Legacy text-based chip (background-color attribute);
                    // keep the substring so old drafts still work.
                    let segment = attributed.attributedSubstring(from: range).string
                    text += segment + " "
                    atts.append(.init(uri: uri, name: segment.trimmingCharacters(in: .init(charactersIn: "@ "))))
                } else {
                    text += attributed.attributedSubstring(from: range).string
                }
            }
            return (text, atts)
        }
    }
}

extension NSAttributedString.Key {
    static let attachmentURI = NSAttributedString.Key("alas.acp.attachmentURI")
}

final class ACPNSTextView: NSTextView {
    weak var coordinator: ACPInputField.Coordinator?

    /// Greyed-out hint drawn when the storage is empty. Matches the Cursor
    /// chat composer's placeholder.
    var placeholderText: String = "Plan, ask, or build — type / for commands"

    /// Live slash-picker panel (nil when no `/` token is active under
    /// the caret). Tracked here so keyDown can intercept arrows / Enter
    /// while it's visible and refreshSlashContext can dismiss it.
    private var slashPanel: ACPSlashPickerPanel?
    /// Character index of the `/` that opened `slashPanel`. Used to
    /// extract the live query and to know what range to replace on
    /// accept.
    private var slashStart: Int = -1

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard (string).isEmpty, !placeholderText.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let origin = NSPoint(
            x: textContainerInset.width + textContainer!.lineFragmentPadding + 1,
            y: textContainerInset.height
        )
        (placeholderText as NSString).draw(at: origin, withAttributes: attrs)
    }

    override func didChangeText() {
        super.didChangeText()
        // Trigger placeholder redraw when text becomes (non-)empty.
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        // Slash-picker keyboard handling — runs BEFORE super so the
        // arrow keys / Enter don't fall through to text-view motion or
        // submit. Esc closes the picker without canceling the prompt.
        if let panel = slashPanel {
            switch event.keyCode {
            case 126: panel.model.moveUp()
            return    // up
            case 125: panel.model.moveDown()
            return    // down
            case 36, 76, 48:                            // return / enter / tab
                if let pick = panel.model.selected() {
                    insertSlash(pick)
                    return
                }
            case 53:                                    // escape
                closeSlashPanel()
                return
            default: break
            }
        }

        if event.charactersIgnoringModifiers == "@" {
            super.keyDown(with: event)
            presentMentionPopover()
            return
        }

        super.keyDown(with: event)

        // After the keystroke is applied to the storage, re-evaluate
        // whether we're sitting on a `/foo…` token. This is what makes
        // the picker reactive — every keystroke either opens, updates,
        // or closes the panel.
        refreshSlashContext()
    }

    private func presentMentionPopover() {
        guard let coord = coordinator else { return }
        let panel = ACPMentionPanel(worktreeRoot: coord.worktreeRoot) { [weak self] file in
            self?.insertMention(file)
        }
        positionAndShow(panel)
    }

    /// Locate an active `/<word>` token at the caret. Active means: the
    /// `/` starts at the beginning of the buffer or right after
    /// whitespace, and everything between it and the caret is
    /// command-shaped (letters / digits / `-` / `_` / `:`). Returns the
    /// `/`'s character index and the current query (without the slash).
    private func currentSlashToken() -> (start: Int, query: String)? {
        let str = (string as NSString)
        let caret = selectedRange().location
        guard caret <= str.length else { return nil }
        var i = caret
        let allowed: Set<Character> = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_:")
        while i > 0 {
            let ch = str.substring(with: NSRange(location: i - 1, length: 1))
            if ch == "/" {
                let prevIsBoundary = i - 1 == 0 || {
                    let pc = str.substring(with: NSRange(location: i - 2, length: 1))
                    return pc == " " || pc == "\n" || pc == "\t"
                }()
                guard prevIsBoundary else { return nil }
                let query = str.substring(with: NSRange(location: i, length: caret - i))
                return (i - 1, query)
            }
            guard let c = ch.first, allowed.contains(c) else { return nil }
            i -= 1
        }
        return nil
    }

    private func refreshSlashContext() {
        guard let coord = coordinator, !coord.promptSuggestions.isEmpty else {
            closeSlashPanel()
            return
        }
        guard let tok = currentSlashToken() else {
            closeSlashPanel()
            return
        }
        if slashPanel == nil { presentSlashPanel() }
        slashStart = tok.start
        slashPanel?.model.setQuery(tok.query)
    }

    private func presentSlashPanel() {
        guard let coord = coordinator, !coord.promptSuggestions.isEmpty,
              let theme = coord.theme else { return }
        let panel = ACPSlashPickerPanel(
            suggestions: coord.promptSuggestions,
            theme: theme
        ) { [weak self] s in self?.insertSlash(s) }
        slashPanel = panel
        positionAndShow(panel, makeKey: false)
    }

    private func closeSlashPanel() {
        slashPanel?.close()
        slashPanel = nil
        slashStart = -1
    }

    /// Public hooks used by the coordinator's `doCommandBy:` fallback so
    /// the Esc / `cancelOperation:` selector can dismiss the panel
    /// without reaching across private state.
    var isSlashPanelOpen: Bool { slashPanel != nil }
    func dismissSlashPanel() { closeSlashPanel() }

    private func insertMention(_ url: URL) {
        let name = url.lastPathComponent
        let attachment = ACPMentionChipAttachment(displayName: name, uri: url.absoluteString)
        let chipString = NSMutableAttributedString(attachment: attachment)
        // Tag the chip's character range with the uri so submission can
        // recover the mention.
        chipString.addAttributes([
            .attachmentURI: url.absoluteString,
            .toolTip: url.path,
        ], range: NSRange(location: 0, length: chipString.length))
        chipString.append(NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: 13)]))
        textStorage?.append(chipString)
        setSelectedRange(NSRange(location: (textStorage?.length ?? 0), length: 0))
        didChangeText()
    }

    private func insertSlash(_ suggestion: ACPPromptSuggestion) {
        guard let ts = textStorage else { return }
        let caret = selectedRange().location
        // Replace the live slash token (`/foo`) with the picked command
        // plus a trailing space so the user can immediately type the
        // argument. Falls back to a plain append if we somehow lost the
        // slash range.
        let replacement = suggestion.command + " "
        if slashStart >= 0, caret >= slashStart {
            let range = NSRange(location: slashStart, length: caret - slashStart)
            ts.replaceCharacters(in: range, with: replacement)
            let newCaret = slashStart + (replacement as NSString).length
            setSelectedRange(NSRange(location: newCaret, length: 0))
        } else {
            ts.append(NSAttributedString(string: replacement))
        }
        closeSlashPanel()
        didChangeText()
    }

    private func positionAndShow(_ panel: NSPanel, makeKey: Bool = true) {
        guard let window = self.window else { return }
        let caretRect = firstRect(forCharacterRange: selectedRange(), actualRange: nil)
        panel.setFrameTopLeftPoint(NSPoint(x: caretRect.minX, y: caretRect.minY))
        window.addChildWindow(panel, ordered: .above)
        if makeKey {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFront(nil)
        }
    }
}

/// Glass NSPanel hosting the SwiftUI fuzzy file picker. Floats above
/// the composer when the user types '@'.
final class ACPMentionPanel: NSPanel {
    init(worktreeRoot: URL, onPick: @escaping (URL) -> Void) {
        super.init(
            contentRect: .init(x: 0, y: 0, width: 360, height: 280),
            styleMask: [.borderless, .nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.isFloatingPanel = true
        self.hasShadow = true
        self.backgroundColor = .clear
        self.isOpaque = false
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.hidesOnDeactivate = true

        let host = NSHostingView(rootView: ACPMentionPickerView(
            worktreeRoot: worktreeRoot,
            onPick: { [weak self] url in
                self?.close()
                onPick(url)
            },
            onCancel: { [weak self] in
                self?.close()
            }
        ))
        host.frame = contentView?.bounds ?? .init(x: 0, y: 0, width: 360, height: 280)
        host.autoresizingMask = [.width, .height]
        contentView?.addSubview(host)
    }

    override var canBecomeKey: Bool { true }
}

// (The reactive slash picker lives in ACPSlashPicker.swift.)
