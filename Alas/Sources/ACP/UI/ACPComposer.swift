import SwiftUI
import AppKit
import UniformTypeIdentifiers

typealias ACPComposerSubmitCompletion = @MainActor (_ succeeded: Bool) -> Void
typealias ACPComposerSubmitHandler = (
    _ text: String,
    _ attachments: [ACPMessage.Attachment],
    _ intent: ACPSubmitIntent,
    _ draft: ACPComposerDraft,
    _ completion: @escaping ACPComposerSubmitCompletion
) -> Bool

struct ACPInputField: NSViewRepresentable {
    @ObservedObject var session: ACPSession
    @ObservedObject var composer: ACPComposerState
    let worktreeRoot: URL
    let actions: ACPComposerActions
    let dropRouter: ACPComposerDropRouter
    @Binding var isFocused: Bool
    let focusRequest: Int
    /// True when ⏎ should submit with `.auto` intent (the default mapping
    /// — queue while busy). False when the user inverted the setting so
    /// ⏎ steers; the placeholder reverses accordingly while busy.
    let sendOnEnter: Bool
    let typography: ACPChatTypography
    /// Persists the current composer draft after text storage changes.
    let onDraftChange: (ACPComposerDraft) -> Void
    /// Clears the persisted draft after an accepted submission.
    let onDraftClear: () -> Void
    /// Stops the composer's dictation session (if one is active) without
    /// touching committed text — called when Esc is pressed or the
    /// composer is torn down (tab switch, window close).
    let onStopDictation: () -> Void
    /// Returns `true` when the host accepted the submission (and the
    /// textview should be cleared) or `false` to keep the draft in
    /// place (e.g. session not ready, prompt already in flight).
    let onSubmit: ACPComposerSubmitHandler
    /// Called when image staging fails so the chrome can show a transient
    /// notice. Receives the specific error that caused the failure.
    let onImageError: (ACPImageStaging.StagingError) -> Void
    /// Async file list provider for the @-mention picker. When nil,
    /// falls back to a synchronous `FileManager` enumerator.
    let filesProvider: (@Sendable () async -> [URL])?

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ACPNSTextView()
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        textView.applyChatTypography(typography)
        textView.isRichText = true
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.focusRingType = .none
        textView.textColor = NSColor(named: "fg") ?? NSColor.labelColor
        textView.insertionPointColor = NSColor.controlAccentColor
        context.coordinator.textView = textView
        dropRouter.attach(textView)
        context.coordinator.onImageError = onImageError
        textView.registerForDraggedTypes([.fileURL, .png, .tiff])
        context.coordinator.restoreInitialDraft(into: textView)
        // Publish the submit closure so the SwiftUI send button can fire
        // the same code path as ⏎.
        let coord = context.coordinator
        actions.submitWithIntent = { [weak coord] intent in
            guard let coord, let tv = coord.textView else { return }
            coord.submit(tv, intent: intent)
        }
        actions.presentImagePicker = { [weak coord] in
            guard let coord, let tv = coord.textView as? ACPNSTextView else { return }
            tv.presentImagePicker()
        }
        actions.applyDictationTranscript = { [weak coord] text, isFinal in
            guard let coord, let tv = coord.textView as? ACPNSTextView else { return }
            tv.replaceDictationRegion(text, isFinal: isFinal)
        }
        actions.cancelDictationRegion = { [weak coord] in
            guard let coord, let tv = coord.textView as? ACPNSTextView else { return }
            tv.cancelDictationRegion()
        }
        actions.insertQuote = { [weak coord] message in
            guard let coord, let textView = coord.textView else { return }
            coord.insertQuote(message, into: textView)
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
        context.coordinator.isFocused = $isFocused
        // The agent can send `available_commands_update` at any time — after
        // the user has already typed a "/" token (e.g. right after a
        // takeover re-attaches via session/load), or to replace/clear an
        // already-open panel's list. reconcileSlashPanel only runs on
        // keystrokes, so without this the panel would miss all of that.
        let suggestionsChanged = context.coordinator.promptSuggestions != session.promptSuggestions
        context.coordinator.promptSuggestions = session.promptSuggestions
        context.coordinator.theme = context.environment.theme
        context.coordinator.sendOnEnter = sendOnEnter
        context.coordinator.typography = typography
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            if let tv = nsView.documentView as? ACPNSTextView,
               let window = tv.window {
                window.makeFirstResponder(tv)
            }
        }
        if let tv = nsView.documentView as? ACPNSTextView {
            tv.applyChatTypography(typography)
            tv.placeholderText = Self.placeholder(for: session.transcript.streamingState, sendOnEnter: sendOnEnter)
            tv.needsDisplay = true
            context.coordinator.syncPersistedDraft(composer.draft, into: tv)
            if suggestionsChanged {
                tv.reconcileSlashPanel()
            }
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.isFocused.wrappedValue = false
        coordinator.flushPendingRestyleNow()
        coordinator.onStopDictation()
        if let tv = nsView.documentView as? ACPNSTextView {
            coordinator.dropRouter.detach(tv)
            tv.dismissFloatingPanels()
            coordinator.editorUndoManager.removeAllActions()
        }
    }

    /// When busy, the placeholder advertises whichever action ⏎ will
    /// trigger under the current settings — so a user who inverted the
    /// shortcut (sendOnEnter = false) sees "Steer the agent…" instead of
    /// being told ⏎ queues.
    static func placeholder(for state: ACPSession.StreamingState,
                            sendOnEnter: Bool) -> String {
        switch state {
        case .idle: return "Plan, ask, or build — type / for commands"
        case .sending, .streaming, .awaitingPermission, .awaitingInput:
            return sendOnEnter
                ? "Queue a follow-up… (⌥⏎ to steer)"
                : "Steer the agent… (⌥⏎ to queue)"
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            worktreeRoot: worktreeRoot,
            initialDraft: composer.draft,
            isFocused: $isFocused,
            focusRequest: focusRequest,
            sendOnEnter: sendOnEnter,
            typography: typography,
            onDraftChange: onDraftChange,
            onDraftClear: onDraftClear,
            onStopDictation: onStopDictation,
            onSubmit: onSubmit,
            filesProvider: filesProvider,
            dropRouter: dropRouter
        )
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let editorUndoManager = UndoManager()
        let worktreeRoot: URL
        let initialDraft: ACPComposerDraft
        var isFocused: Binding<Bool>
        var focusRequest: Int
        /// Keyboard-only inversion flag. The coordinator resolves the
        /// raw modifier-derived intent (`.auto` for ⏎, `.steer` for ⌥⏎)
        /// against this and emits a FINAL intent to `onSubmit`. The
        /// toolbar send button bypasses the coordinator's keyboard
        /// handler, so mouse clicks are never inverted — clicking the
        /// visible ↑ button always submits with the intent the button's
        /// help text advertises.
        var sendOnEnter: Bool
        var typography: ACPChatTypography
        let onDraftChange: (ACPComposerDraft) -> Void
        let onDraftClear: () -> Void
        let onStopDictation: () -> Void
        let onSubmit: ACPComposerSubmitHandler
        let filesProvider: (@Sendable () async -> [URL])?
        let dropRouter: ACPComposerDropRouter
        var promptSuggestions: [ACPPromptSuggestion] = []
        /// Snapshotted at makeNSView time so the AppKit-only slash panel
        /// can render its SwiftUI content with our theme tokens.
        var theme: Theme?
        weak var textView: NSTextView?
        /// Set by the composer chrome to surface staging failures (Task 14).
        var onImageError: ((ACPImageStaging.StagingError) -> Void)?
        private var restoringDraft = false
        private var lastSyncedDraft: ACPComposerDraft

        func undoManager(for view: NSTextView) -> UndoManager? { editorUndoManager }
        private var nextSubmitID = 0
        private var pendingSubmitID: Int?
        private var pendingImageFileInsertions = 0
        private var imageFileInsertionGeneration = 0
        private var pendingRestyleWork: DispatchWorkItem?
        private var pendingRestyleGeneration = 0
        private var pendingRestyleRange: NSRange?
        private static let restyleDebounceInterval: Double = 0.5

        func reportImageError(_ error: ACPImageStaging.StagingError) {
            onImageError?(error)
        }

        func flushPendingRestyleNow() {
            guard let work = pendingRestyleWork else { return }
            pendingRestyleWork = nil
            work.perform()
            pendingRestyleGeneration += 1
            work.cancel()
        }

        init(
            worktreeRoot: URL,
            initialDraft: ACPComposerDraft,
            isFocused: Binding<Bool> = .constant(false),
            focusRequest: Int,
            sendOnEnter: Bool,
            typography: ACPChatTypography = .default,
            onDraftChange: @escaping (ACPComposerDraft) -> Void,
            onDraftClear: @escaping () -> Void,
            onStopDictation: @escaping () -> Void = {},
            onSubmit: @escaping ACPComposerSubmitHandler,
            filesProvider: (@Sendable () async -> [URL])? = nil,
            dropRouter: ACPComposerDropRouter = ACPComposerDropRouter()
        ) {
            self.worktreeRoot = worktreeRoot
            self.initialDraft = initialDraft
            self.isFocused = isFocused
            self.focusRequest = focusRequest
            self.sendOnEnter = sendOnEnter
            self.typography = typography
            self.lastSyncedDraft = initialDraft
            self.onDraftChange = onDraftChange
            self.onDraftClear = onDraftClear
            self.onStopDictation = onStopDictation
            self.onSubmit = onSubmit
            self.filesProvider = filesProvider
            self.dropRouter = dropRouter
        }

        func textDidBeginEditing(_ notification: Notification) {
            isFocused.wrappedValue = true
        }

        func textDidEndEditing(_ notification: Notification) {
            if let tv = notification.object as? ACPNSTextView {
                tv.dismissSlashPanel()
            }
            isFocused.wrappedValue = false
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // Belt-and-suspenders Esc handling. keyDown already catches
            // keyCode 53 to close the slash panel, but NSTextView also
            // routes Esc through `cancelOperation:` after the input
            // method system gets a crack at it. If the panel is still
            // open here, close it and swallow the event.
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                // Harmless no-op when dictation isn't active.
                onStopDictation()
                if let tv = textView as? ACPNSTextView, tv.isSlashPanelOpen {
                    tv.dismissSlashPanel()
                    return true
                }
            }
            // ⌥⏎ steers. AppKit's standard key binding routes Option-Return
            // to `insertNewlineIgnoringFieldEditor:`, NOT `insertNewline:`,
            // so it MUST be caught explicitly — otherwise it falls through
            // to AppKit's default and just inserts a literal newline (the
            // bug this handler exists to prevent). We resolve the keyboard
            // mapping HERE so the upstream handler receives a final intent;
            // the toolbar send button bypasses this via
            // `actions.submitWithIntent` and submits the intent it
            // advertises verbatim.
            if selector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
                submit(textView, intent: resolvedIntent(raw: .steer))
                return true
            }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                // ⇧⏎ inserts a literal newline. (⌥⏎ never reaches here — it
                // routes to `insertNewlineIgnoringFieldEditor:` above.)
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    textView.insertText("\n", replacementRange: textView.selectedRange())
                    return true
                }
                submit(textView, intent: resolvedIntent(raw: .auto))
                return true
            }
            return false
        }

        /// Apply the keyboard-only `sendOnEnter` inversion to a raw
        /// modifier-derived intent. When the user inverted the setting,
        /// ⏎ and ⌥⏎ swap roles, so `.auto` ↔ `.steer`.
        private func resolvedIntent(raw: ACPSubmitIntent) -> ACPSubmitIntent {
            sendOnEnter ? raw : (raw == .auto ? .steer : .auto)
        }

        /// Re-apply markdown styling to the whole storage on every edit.
        /// Bold `**…**`, italic `*…*` / `_…_`, inline `` `…` ``. Block-level
        /// (#/```) is handled on the receiving side via ACPMarkdownText.
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView,
                  let storage = tv.textStorage
            else { return }
            guard !restoringDraft else { return }
            pendingSubmitID = nil
            if storage.string.isEmpty {
                invalidatePendingImageFileInsertions()
            }
            if let tv = tv as? ACPNSTextView {
                tv.reconcileSlashPanel()
            }
            let draft = Self.draft(from: storage)
            lastSyncedDraft = draft
            onDraftChange(draft)
            pendingRestyleRange = pendingRestyleRange.map { existing in
                NSUnionRange(existing, ACPMarkdownLiveStyler.editedLineRange(in: storage) ?? existing)
            } ?? ACPMarkdownLiveStyler.editedLineRange(in: storage)
            pendingRestyleWork?.cancel()
            pendingRestyleGeneration += 1
            let generation = pendingRestyleGeneration
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                guard self.pendingRestyleGeneration == generation else { return }
                ACPMarkdownLiveStyler.restyle(
                    storage,
                    in: self.pendingRestyleRange,
                    typography: self.typography
                )
                self.pendingRestyleRange = nil
                self.pendingRestyleWork = nil
            }
            pendingRestyleWork = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.restyleDebounceInterval,
                execute: work
            )
        }

        func submit(_ textView: NSTextView, intent: ACPSubmitIntent = .auto) {
            guard pendingImageFileInsertions == 0 else { return }
            flushPendingRestyleNow()
            if let tv = textView as? ACPNSTextView {
                tv.dismissSlashPanel()
            }
            let attributed = textView.attributedString()
            let (text, attachments) = Self.extract(attributed)
            // Allow image-only prompts: an attached image carries no text, so
            // submit must be gated on text OR attachments, not text alone.
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !attachments.isEmpty else { return }
            let draft = Self.draft(from: attributed)
            // Rejected submits keep the editable draft in place. Accepted
            // submits clear only the visible text view here; persisted
            // draft deletion waits for the async prompt completion.
            let submitID = nextSubmitID
            nextSubmitID += 1
            if onSubmit(text, attachments, intent, draft, { [weak self, weak textView] succeeded in
                if let self {
                    self.finishSubmit(id: submitID, draft: draft, succeeded: succeeded, textView: textView)
                }
                // Durable draft finalization lives with the submit owner, so
                // tab switches can outlive this coordinator.
            }) {
                pendingSubmitID = submitID
                clearVisibleDraft(in: textView)
            }
        }

        func insertQuote(_ message: String, into textView: NSTextView) {
            guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            if let textView = textView as? ACPNSTextView {
                textView.dismissSlashPanel()
            }

            let selection = textView.selectedRange()
            let source = textView.string as NSString
            let needsLeadingNewline = selection.location > 0
                && source.character(at: selection.location - 1) != 0x0A
            let suffixLocation = NSMaxRange(selection)
            let needsTrailingSpacer = suffixLocation < source.length
                && source.character(at: suffixLocation) != 0x0A
            let leading = needsLeadingNewline ? "\n" : ""
            let quoted = ACPMessageQuote.markdown(message)
            let caretPrefix = leading + quoted + "\n"
            let replacement = caretPrefix + (needsTrailingSpacer ? "\n" : "")

            textView.typingAttributes = [
                .font: typography.appKitFont(),
                .foregroundColor: NSColor.labelColor,
            ]
            textView.insertText(replacement, replacementRange: selection)
            textView.setSelectedRange(NSRange(
                location: selection.location + (caretPrefix as NSString).length,
                length: 0
            ))
            textView.window?.makeFirstResponder(textView)
        }

        func beginPendingImageFileInsertion() -> Int {
            pendingImageFileInsertions += 1
            return imageFileInsertionGeneration
        }

        func finishPendingImageFileInsertion(generation: Int) {
            if generation == imageFileInsertionGeneration {
                pendingImageFileInsertions = max(0, pendingImageFileInsertions - 1)
            }
        }

        func canCompleteImageFileInsertion(generation: Int) -> Bool {
            generation == imageFileInsertionGeneration
        }

        private func invalidatePendingImageFileInsertions() {
            imageFileInsertionGeneration &+= 1
            pendingImageFileInsertions = 0
        }

        func restoreInitialDraft(into textView: NSTextView) {
            guard !initialDraft.isEmpty else { return }
            restore(initialDraft, into: textView)
        }

        func syncPersistedDraft(_ draft: ACPComposerDraft, into textView: NSTextView) {
            let currentDraft = Self.draft(from: textView.attributedString())
            if currentDraft == draft {
                lastSyncedDraft = draft
                return
            }
            guard currentDraft == lastSyncedDraft else { return }
            restore(draft, into: textView)
        }

        private func restore(_ draft: ACPComposerDraft, into textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            if let tv = textView as? ACPNSTextView {
                tv.dismissSlashPanel()
            }
            invalidatePendingImageFileInsertions()
            restoringDraft = true
            storage.setAttributedString(Self.attributedString(from: draft, typography: typography))
            ACPMarkdownLiveStyler.restyle(storage, typography: typography)
            textView.needsDisplay = true
            restoringDraft = false
            lastSyncedDraft = draft
        }

        private func clearVisibleDraft(in textView: NSTextView) {
            if let tv = textView as? ACPNSTextView {
                tv.dismissSlashPanel()
            }
            invalidatePendingImageFileInsertions()
            restoringDraft = true
            textView.string = ""
            textView.needsDisplay = true
            restoringDraft = false
        }

        private func finishSubmit(
            id: Int,
            draft: ACPComposerDraft,
            succeeded: Bool,
            textView: NSTextView?
        ) {
            guard pendingSubmitID == id else { return }
            pendingSubmitID = nil
            if succeeded {
                onDraftClear()
            } else {
                onDraftChange(draft)
                if let textView {
                    restore(draft, into: textView)
                }
            }
        }

        static func draft(from attributed: NSAttributedString) -> ACPComposerDraft {
            let full = NSRange(location: 0, length: attributed.length)
            guard attributed.length > 0 else { return ACPComposerDraft(segments: []) }

            // Fast path: no chip mentions or image chips in the storage.
            // The whole string is plain text, so skip the enumerateAttributes
            // walk entirely. This is the common case while typing.
            var hasChip = false
            attributed.enumerateAttributes(in: full) { keys, _, stop in
                if keys[.attachmentURI] != nil || keys[.imageAttachmentURI] != nil {
                    hasChip = true
                    stop.pointee = true
                }
            }
            if !hasChip {
                let text = attributed.string
                return ACPComposerDraft(segments: text.isEmpty ? [] : [.text(text)])
            }

            var segments: [ACPComposerDraft.Segment] = []
            attributed.enumerateAttributes(in: full) { keys, range, _ in
                if let uri = keys[.imageAttachmentURI] as? String {
                    let mime = (keys[.imageAttachmentMime] as? String) ?? "image/png"
                    segments.append(.image(uri: uri, mimeType: mime))
                } else if let uri = keys[.attachmentURI] as? String {
                    if let chip = attributed.attribute(.attachment, at: range.location, effectiveRange: nil)
                       as? ACPMentionChipAttachment {
                        segments.append(.mention(displayName: chip.displayName, uri: uri))
                    } else {
                        let segment = attributed.attributedSubstring(from: range).string
                        let displayName = segment.trimmingCharacters(in: .init(charactersIn: "@ "))
                        segments.append(.mention(displayName: displayName, uri: uri))
                    }
                } else {
                    let text = attributed.attributedSubstring(from: range).string
                    if !text.isEmpty { segments.append(.text(text)) }
                }
            }
            return ACPComposerDraft(segments: segments)
        }

        static func attributedString(
            from draft: ACPComposerDraft,
            typography: ACPChatTypography = .default
        ) -> NSAttributedString {
            let result = NSMutableAttributedString(string: "")
            let baseAttributes: [NSAttributedString.Key: Any] = [
                .font: typography.appKitFont(),
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
                case .image(let uri, let mimeType):
                    // Drop the chip if the staged file is gone — a deleted
                    // attachment shouldn't restore as a broken placeholder or
                    // get sent as a dangling resource link.
                    guard let fileURL = URL(string: uri),
                          FileManager.default.fileExists(atPath: fileURL.path) else { break }
                    let attachment = ACPImageChipAttachment(fileURL: fileURL, mimeType: mimeType)
                    let chip = NSMutableAttributedString(attachment: attachment)
                    chip.addAttributes([
                        .imageAttachmentURI: uri,
                        .imageAttachmentMime: mimeType,
                        .toolTip: fileURL.lastPathComponent,
                    ], range: NSRange(location: 0, length: chip.length))
                    result.append(chip)
                }
            }
            return result
        }

        /// Walks the attributed string. Image chips (tagged with
        /// `.imageAttachmentURI`) become image attachments and contribute NO
        /// text. Mention chips (tagged with `.attachmentURI`) become
        /// resource_link attachments and emit `@filename` in the text.
        /// Everything else is concatenated as-is — the user's markdown
        /// markers (`**bold**`, `# heading`, etc.) are preserved verbatim for
        /// the receiving agent.
        static func extract(_ attributed: NSAttributedString) -> (String, [ACPMessage.Attachment]) {
            var text = ""
            var atts: [ACPMessage.Attachment] = []
            let full = NSRange(location: 0, length: attributed.length)
            attributed.enumerateAttributes(in: full) { keys, range, _ in
                if let uri = keys[.imageAttachmentURI] as? String {
                    let mime = (keys[.imageAttachmentMime] as? String) ?? "image/png"
                    let name = URL(string: uri)?.lastPathComponent
                    atts.append(.init(uri: uri, name: name, mimeType: mime))
                    // Image chips contribute NO text.
                } else if let uri = keys[.attachmentURI] as? String {
                    if let chip = attributed.attribute(.attachment, at: range.location, effectiveRange: nil)
                                as? ACPMentionChipAttachment {
                        text += "@" + chip.displayName + " "
                        atts.append(.init(uri: uri, name: chip.displayName))
                    } else {
                        let segment = attributed.attributedSubstring(from: range).string
                        text += segment + " "
                        atts.append(.init(uri: uri, name: segment.trimmingCharacters(in: .init(charactersIn: "@ "))))
                    }
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
    static let imageAttachmentURI = NSAttributedString.Key("alas.acp.imageAttachmentURI")
    static let imageAttachmentMime = NSAttributedString.Key("alas.acp.imageAttachmentMime")
}

final class ACPNSTextView: PairedDelimiterTextView {
    weak var coordinator: ACPInputField.Coordinator?
    private var chatTypography: ACPChatTypography = .default

    #if DEBUG
    nonisolated(unsafe) static var imageFileReadGateForTesting: (@Sendable () async -> Void)?
    #endif

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
    private var mentionPanel: ACPMentionPanel?
    private var mentionStart: Int = -1

    private var baseTypingAttributes: [NSAttributedString.Key: Any] {
        [
            .font: chatTypography.appKitFont(),
            .foregroundColor: NSColor.labelColor,
        ]
    }

    func applyChatTypography(_ typography: ACPChatTypography) {
        guard chatTypography != typography || font == nil else { return }
        chatTypography = typography
        font = typography.appKitFont()
        typingAttributes = baseTypingAttributes
        if let textStorage {
            ACPMarkdownLiveStyler.restyle(textStorage, typography: typography)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard (string).isEmpty, !placeholderText.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? chatTypography.appKitFont(),
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
        // A dictation span's tracked range is only valid until the next
        // edit — typing elsewhere, pasting, or any other change shifts
        // offsets without updating it. `replaceDictationRegion` itself
        // sets `isApplyingDictationUpdate` around its own edit so this
        // doesn't invalidate the span it just wrote; anything else means
        // a manual edit landed while a span was open, so the next
        // transcript update must start fresh rather than replace
        // characters that moved.
        if dictationRange != nil, !isApplyingDictationUpdate {
            dictationRange = nil
        }
    }

    /// A restored draft can already contain an active "/" token before
    /// this view is attached to a window — `positionAndShow` needs the
    /// window to place the panel, so `reconcileSlashPanel` is a no-op
    /// until attachment. Retry once a window exists.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            reconcileSlashPanel()
        }
    }

    /// Dismiss any floating picker panel owned by this text view. The
    /// panels are attached as child windows of the host window (not of
    /// this view), so without an explicit close on teardown they outlive
    /// the composer and stay visible across tab switches until app quit.
    /// `dismantleNSView` calls this when the SwiftUI representable is
    /// torn down (tab switch, window close).
    func dismissFloatingPanels() {
        dismissSlashPanel()
        closeMentionPanel()
    }

    override func keyDown(with event: NSEvent) {
        typingAttributes = baseTypingAttributes

        // ⌃V parity with agent CLIs — paste an image when one is on the
        // clipboard. Only intercept when there IS an image, so Cocoa's
        // default ⌃V (page down / emacs binding) is otherwise preserved.
        if event.modifierFlags.contains(.control),
           event.charactersIgnoringModifiers?.lowercased() == "v",
           pasteboardHasImage {
            paste(nil)
            return
        }

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
                // Harmless no-op when dictation isn't active. Without this,
                // Esc while the slash panel is open returns here before
                // `doCommandBy:`'s cancelOperation handling ever runs,
                // silently skipping the same stop that bare Esc performs.
                coordinator?.onStopDictation()
                closeSlashPanel()
                return
            default: break
            }
        }

        if event.charactersIgnoringModifiers == "@" {
            let triggerLocation = selectedRange().location
            super.keyDown(with: event)
            mentionStart = triggerLocation
            presentMentionPopover()
            return
        }

        super.keyDown(with: event)
        typingAttributes = baseTypingAttributes

        // After the keystroke is applied to the storage, re-evaluate
        // whether we're sitting on a `/foo…` token. This is what makes
        // the picker reactive — every keystroke either opens, updates,
        // or closes the panel.
        reconcileSlashPanel()
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        reconcileSlashPanel()
    }

    private func presentMentionPopover() {
        guard let coord = coordinator else { return }
        closeMentionPanel()
        let panel = ACPMentionPanel(
            worktreeRoot: coord.worktreeRoot,
            filesProvider: coord.filesProvider,
            onPick: { [weak self] file in
                self?.insertMention(file)
            },
            onCancel: { [weak self] in
                self?.closeMentionPanel()
            }
        )
        mentionPanel = panel
        positionAndShow(panel)
    }

    private func closeMentionPanel() {
        mentionPanel?.close()
        mentionPanel = nil
        mentionStart = -1
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

    func reconcileSlashPanel() {
        guard let coord = coordinator, !coord.promptSuggestions.isEmpty else {
            closeSlashPanel()
            return
        }
        guard let tok = currentSlashToken() else {
            closeSlashPanel()
            return
        }
        if slashPanel == nil {
            presentSlashPanel()
        } else {
            slashPanel?.model.updateSuggestions(coord.promptSuggestions)
        }
        slashStart = tok.start
        slashPanel?.model.setQuery(tok.query)
        if slashPanel?.model.filtered.isEmpty == true {
            closeSlashPanel()
        }
    }

    private func presentSlashPanel() {
        // `positionAndShow` needs `window` to place the panel; bail out
        // rather than recording a `slashPanel` that was never actually
        // shown — reconcileSlashPanel would then skip re-presenting it
        // on later calls, leaving it permanently invisible.
        guard window != nil, let coord = coordinator, !coord.promptSuggestions.isEmpty,
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

    var worktreeIdForStaging: String {
        coordinator?.worktreeRoot.lastPathComponent ?? "default"
    }

    static let maxImagesPerMessage = 10

    private func currentImageChipCount() -> Int {
        guard let storage = textStorage else { return 0 }
        var count = 0
        storage.enumerateAttribute(.imageAttachmentURI, in: NSRange(location: 0, length: storage.length)) { v, _, _ in
            if v != nil { count += 1 }
        }
        return count
    }

    @discardableResult
    func insertImage(data: Data, worktreeId: String) -> Bool {
        insertImage(data: data, worktreeId: worktreeId, replacementRange: selectedRange())
    }

    @discardableResult
    private func insertImage(data: Data, worktreeId: String, replacementRange: NSRange) -> Bool {
        guard currentImageChipCount() < Self.maxImagesPerMessage else {
            coordinator?.reportImageError(.tooManyImages)
            return false
        }
        do {
            let staged = try ACPImageStaging.stage(data: data, into: worktreeId)
            let attachment = ACPImageChipAttachment(fileURL: staged.url, mimeType: staged.mimeType)
            let chipString = NSMutableAttributedString(attachment: attachment)
            chipString.addAttributes([
                .imageAttachmentURI: staged.url.absoluteString,
                .imageAttachmentMime: staged.mimeType,
                .toolTip: staged.url.lastPathComponent,
            ], range: NSRange(location: 0, length: chipString.length))
            // Color the trailing space and reset typingAttributes so text the
            // user types right after the chip is the normal label color
            // immediately — otherwise it inherits color-less attributes and
            // renders black until the debounced restyler repaints the line.
            let baseAttrs = baseTypingAttributes
            chipString.append(NSAttributedString(string: " ", attributes: baseAttrs))
            let storageLength = textStorage?.length ?? 0
            let location = min(replacementRange.location, storageLength)
            let insertAt = NSRange(location: location, length: min(replacementRange.length, storageLength - location))
            textStorage?.replaceCharacters(in: insertAt, with: chipString)
            setSelectedRange(NSRange(location: insertAt.location + chipString.length, length: 0))
            typingAttributes = baseAttrs
            didChangeText()
            return true
        } catch let error as ACPImageStaging.StagingError {
            coordinator?.reportImageError(error)
            return false
        } catch {
            coordinator?.reportImageError(.writeFailed)
            return false
        }
    }

    func presentImagePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP]
        panel.begin { [weak self] response in
            guard let self, response == .OK else { return }
            self.insertImageFiles(
                panel.urls,
                worktreeId: self.worktreeIdForStaging,
                insertionRange: self.selectedRange()
            )
        }
    }

    /// Cheap probe: does `pb` hold a supported image, WITHOUT reading whole
    /// files? Inspects pasteboard types for raw image data and peeks only the
    /// header + size of image file URLs, so hovering a huge file during a drag
    /// (or a ⌃V availability check) doesn't allocate the whole file.
    private func hasImage(in pb: NSPasteboard) -> Bool {
        let types = pb.types ?? []
        if types.contains(.png) || types.contains(.tiff) { return true }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            return urls.contains { Self.isSupportedImageFile($0) }
        }
        return false
    }

    /// True when `url` is a supported image within the size cap, decided by
    /// reading only its first bytes — never the whole file.
    private static func isSupportedImageFile(_ url: URL) -> Bool {
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > ACPImageStaging.maxBytes { return false }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let header = (try? handle.read(upToCount: 16)) ?? Data()
        return ACPImageStaging.sniffMIME(header) != nil
    }

    enum FileImageRead {
        case data(Data)
        case tooLarge
        case unsupported
    }

    private enum FileImageCandidate {
        case supported
        case tooLarge
        case unsupported
    }

    private static func imageFileCandidate(_ url: URL) -> FileImageCandidate {
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > ACPImageStaging.maxBytes { return .tooLarge }
        return isSupportedImageFile(url) ? .supported : .unsupported
    }

    /// Read a file URL's image bytes, applying the size cap from its metadata
    /// BEFORE reading the file into memory (so an oversized pick/drop reports
    /// `.tooLarge` instead of allocating the whole file). The file read and
    /// MIME sniff happen in a `Task.detached` so the main thread isn't blocked.
    static func readImageFile(_ url: URL) async -> FileImageRead {
        await Task.detached(priority: .userInitiated) {
            #if DEBUG
            if let gate = await ACPNSTextView.imageFileReadGateForTesting {
                await gate()
            }
            #endif
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size > ACPImageStaging.maxBytes { return .tooLarge }
            guard let handle = try? FileHandle(forReadingFrom: url) else { return .unsupported }
            let header = (try? handle.read(upToCount: 16)) ?? Data()
            try? handle.close()
            guard ACPImageStaging.sniffMIME(header) != nil,
                  let data = try? Data(contentsOf: url) else { return .unsupported }
            return .data(data)
        }.value
    }

    /// Stage and insert every supported image from `pb` — raw bitmap data
    /// (one screenshot) or one-per image file URL (multiple Finder files). Each
    /// `insertImage` enforces the per-message cap; oversized file URLs surface
    /// the `.tooLarge` notice. Returns true if any image source was handled.
    /// File-URL reads are dispatched off the main thread; pasteboard bitmap
    /// data (already in memory) is handled inline.
    @discardableResult
    private func insertImages(from pb: NSPasteboard) -> Bool {
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pb.data(forType: type) {
                if type == .tiff, let rep = NSBitmapImageRep(data: data),
                   let png = rep.representation(using: .png, properties: [:]) {
                    _ = insertImage(data: png, worktreeId: worktreeIdForStaging)
                    return true
                }
                if ACPImageStaging.sniffMIME(data) != nil {
                    _ = insertImage(data: data, worktreeId: worktreeIdForStaging)
                    return true
                }
            }
        }
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        else { return false }
        guard !urls.isEmpty else { return false }
        guard urls.contains(where: { Self.imageFileCandidate($0) != .unsupported }) else { return false }
        insertImageFiles(urls, worktreeId: worktreeIdForStaging, insertionRange: selectedRange())
        return true
    }

    private func insertImageFiles(_ urls: [URL], worktreeId: String, insertionRange: NSRange) {
        let coordinator = coordinator
        let generation = coordinator?.beginPendingImageFileInsertion()
        Task { @MainActor [weak self, weak coordinator] in
            defer {
                if let generation {
                    coordinator?.finishPendingImageFileInsertion(generation: generation)
                }
            }
            var nextLocation = insertionRange.location
            var isFirstImage = true
            for url in urls {
                switch await Self.readImageFile(url) {
                case .data(let data):
                    guard let self else { return }
                    if let generation,
                       coordinator?.canCompleteImageFileInsertion(generation: generation) != true { return }
                    let beforeLength = self.textStorage?.length ?? 0
                    let replacementRange = self.asyncImageReplacementRange(
                        capturedRange: insertionRange,
                        nextLocation: nextLocation,
                        isFirstImage: isFirstImage
                    )
                    if self.insertImage(data: data, worktreeId: worktreeId, replacementRange: replacementRange) {
                        nextLocation = self.selectedRange().location
                        if nextLocation == replacementRange.location {
                            nextLocation += max(0, (self.textStorage?.length ?? 0) - beforeLength)
                        }
                        isFirstImage = false
                    }
                case .tooLarge:
                    if let generation,
                       coordinator?.canCompleteImageFileInsertion(generation: generation) != true { return }
                    self?.coordinator?.reportImageError(.tooLarge)
                case .unsupported:
                    break
                }
            }
        }
    }

    #if DEBUG
    func insertPickedImageFilesForTesting(_ urls: [URL]) {
        insertImageFiles(urls, worktreeId: worktreeIdForStaging, insertionRange: selectedRange())
    }
    #endif

    private func asyncImageReplacementRange(
        capturedRange: NSRange,
        nextLocation: Int,
        isFirstImage: Bool
    ) -> NSRange {
        guard isFirstImage else { return NSRange(location: nextLocation, length: 0) }
        let current = selectedRange()
        guard current == capturedRange else { return NSRange(location: current.location, length: 0) }
        return capturedRange
    }

    /// True when the general pasteboard currently holds a supported image.
    private var pasteboardHasImage: Bool { hasImage(in: NSPasteboard.general) }

    override func paste(_ sender: Any?) {
        if insertImages(from: NSPasteboard.general) { return }
        if let text = NSPasteboard.general.string(forType: .string) {
            insertPlainText(text)
            return
        }
        super.paste(sender)
    }

    @discardableResult
    func insertPlainText(_ text: String) -> Bool {
        guard let textStorage else { return false }
        let replacementRange = selectedRange()
        let boundedRange = NSRange(
            location: min(replacementRange.location, textStorage.length),
            length: min(replacementRange.length, max(0, textStorage.length - replacementRange.location))
        )
        let attrs = baseTypingAttributes
        typingAttributes = attrs
        performNativeTextInsertion {
            insertText(text, replacementRange: boundedRange)
        }
        typingAttributes = attrs
        return true
    }

    /// Tracks the not-yet-finalized dictation span so each subsequent
    /// volatile transcript update can replace it in place instead of
    /// appending alongside it. `nil` once a final result commits the span
    /// (the next volatile update then starts a fresh span after the
    /// committed text) or once dictation stops.
    private var dictationRange: NSRange?
    /// Set around `replaceDictationRegion`'s own edit so `didChangeText()`
    /// doesn't mistake it for the manual edit that invalidates the span.
    private var isApplyingDictationUpdate = false

    /// Inserts or replaces the live dictation transcript. Volatile
    /// updates (`isFinal == false`) replace the previous volatile span in
    /// place so mid-utterance corrections don't pile up as duplicate
    /// text. A final update commits the span: the text stays, but the
    /// next volatile update starts a new span appended after it rather
    /// than overwriting it.
    @discardableResult
    func replaceDictationRegion(_ text: String, isFinal: Bool) -> Bool {
        guard let textStorage else { return false }
        let target: NSRange
        if let existing = dictationRange {
            target = NSRange(
                location: min(existing.location, textStorage.length),
                length: min(existing.length, max(0, textStorage.length - existing.location))
            )
        } else {
            target = selectedRange()
        }
        let attrs = baseTypingAttributes
        typingAttributes = attrs
        isApplyingDictationUpdate = true
        performNativeTextInsertion {
            insertText(text, replacementRange: target)
        }
        isApplyingDictationUpdate = false
        typingAttributes = attrs
        let inserted = NSRange(location: target.location, length: (text as NSString).length)
        if isFinal {
            dictationRange = nil
            setSelectedRange(NSRange(location: NSMaxRange(inserted), length: 0))
        } else {
            dictationRange = inserted
        }
        return true
    }

    /// Stops tracking the live dictation span without altering the
    /// committed text — used when dictation is toggled off mid-utterance.
    func cancelDictationRegion() {
        dictationRange = nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasImage(in: sender.draggingPasteboard) ? .copy : super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if insertImages(from: sender.draggingPasteboard) { return true }
        return super.performDragOperation(sender)
    }

    @discardableResult
    func insertMention(_ url: URL) -> Bool {
        guard let textStorage else { return false }
        let name = url.lastPathComponent
        let attachment = ACPMentionChipAttachment(displayName: name, uri: url.absoluteString)
        let chipString = NSMutableAttributedString(attachment: attachment)
        // Tag the chip's character range with the uri so submission can
        // recover the mention.
        chipString.addAttributes([
            .attachmentURI: url.absoluteString,
            .toolTip: url.path,
        ], range: NSRange(location: 0, length: chipString.length))
        let baseAttrs = baseTypingAttributes
        chipString.append(NSAttributedString(string: " ", attributes: baseAttrs))

        let replacementRange = mentionReplacementRange(in: textStorage)
        textStorage.replaceCharacters(in: replacementRange, with: chipString)
        setSelectedRange(NSRange(location: replacementRange.location + chipString.length, length: 0))
        typingAttributes = baseAttrs
        closeMentionPanel()
        didChangeText()
        return true
    }

    private func mentionReplacementRange(in storage: NSTextStorage) -> NSRange {
        let selected = selectedRange()
        let caret = min(selected.location, storage.length)
        let string = storage.string as NSString

        if mentionStart >= 0,
           mentionStart < storage.length,
           caret >= mentionStart,
           string.substring(with: NSRange(location: mentionStart, length: 1)) == "@" {
            return NSRange(location: mentionStart, length: caret - mentionStart + selected.length)
        }

        if selected.length == 0,
           caret > 0,
           string.substring(with: NSRange(location: caret - 1, length: 1)) == "@" {
            return NSRange(location: caret - 1, length: 1)
        }

        return NSRange(location: caret, length: min(selected.length, storage.length - caret))
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
    init(worktreeRoot: URL,
         filesProvider: (@Sendable () async -> [URL])?,
         onPick: @escaping (URL) -> Void,
         onCancel: @escaping () -> Void = {}) {
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
                onCancel()
            },
            filesProvider: filesProvider
        ))
        host.frame = contentView?.bounds ?? .init(x: 0, y: 0, width: 360, height: 280)
        host.autoresizingMask = [.width, .height]
        contentView?.addSubview(host)
    }

    override var canBecomeKey: Bool { true }
}

// (The reactive slash picker lives in ACPSlashPicker.swift.)
