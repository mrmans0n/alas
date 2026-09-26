import SwiftUI
import AppKit
import Combine
import CryptoKit
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

    var nextPromptOffer: String? = nil
    var takeNextPromptOffer: () -> String? = { nil }
    var dismissNextPromptOffer: () -> Void = {}
    var onNextPromptStateChange: (NextPromptEligibilitySnapshot.Environment) -> Void = { _ in }
    var nextPromptInputBlocked: () -> Bool = { false }
    var nextPromptIsDictating: () -> Bool = { false }
    /// Reference-chip cache for this worktree. `nil` disables reference chips.
    var upstreamReferences: ACPUpstreamReferenceStore? = nil

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
        context.coordinator.attachUpstreamReferences(upstreamReferences)
        configureNextPrompt(textView)
        textView.invalidateNextPromptSuggestion()
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
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
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
        if context.coordinator.upstreamReferences !== upstreamReferences {
            context.coordinator.attachUpstreamReferences(upstreamReferences)
        }
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            if let tv = nsView.documentView as? ACPNSTextView,
               let window = tv.window {
                window.makeFirstResponder(tv)
            }
        }
        if let tv = nsView.documentView as? ACPNSTextView {
            configureNextPrompt(tv)
            let baseFont = typography.appKitFont()
            let style = Self.codeBlockStyle(
                theme: context.environment.theme,
                baseFont: baseFont,
                typography: typography
            )
            tv.markdownFencesEnabled = true
            tv.markdownCodeBlockStyle = style
            context.coordinator.codeBlockStyle = style
            tv.applyChatTypography(typography)
            tv.placeholderText = Self.placeholder(for: session.transcript.streamingState, sendOnEnter: sendOnEnter)
            tv.needsDisplay = true
            context.coordinator.syncPersistedDraft(composer.draft, into: tv)
            if suggestionsChanged {
                tv.reconcileSlashPanel()
                // A draft restored before the agent listed its commands
                // gets its pill once the list arrives.
                tv.pillLeadingCommandIfNeeded()
            }
            tv.nextPromptOffer = nextPromptOffer
            if tv.nextPromptGhostText == nil, nextPromptOffer != nil { tv.invalidateNextPromptSuggestion() }
            tv.onNextPromptStateChange(tv.nextPromptInputState)
            tv.refreshNextPromptLayout()
        }
    }

    private func configureNextPrompt(_ textView: ACPNSTextView) {
        textView.takeNextPromptOffer = takeNextPromptOffer
        textView.dismissNextPromptOffer = dismissNextPromptOffer
        textView.onNextPromptStateChange = onNextPromptStateChange
        textView.nextPromptDraftIsEmpty = { composer.draft.isEmpty }
        textView.nextPromptInputBlocked = nextPromptInputBlocked
        textView.nextPromptIsDictating = nextPromptIsDictating
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, let textView = nsView.documentView as? ACPNSTextView else { return nil }
        let contentHeight = min(140, textView.composerContentHeight(for: width))
        // Fill the offered height like a plain flexible NSView would. Hugging
        // the content height lets SwiftUI center a short editor vertically in
        // the composer, so the caret starts mid-box instead of at the top.
        guard let proposedHeight = proposal.height else {
            return CGSize(width: width, height: contentHeight)
        }
        return CGSize(width: width, height: min(140, max(proposedHeight, contentHeight)))
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.isFocused.wrappedValue = false
        coordinator.flushPendingRestyleNow()
        coordinator.onStopDictation()
        if let tv = nsView.documentView as? ACPNSTextView {
            tv.invalidateNextPromptSuggestion()
            tv.onNextPromptStateChange(.init())
            tv.onNextPromptStateChange = { _ in }
            coordinator.dropRouter.detach(tv)
            tv.dismissFloatingPanels()
            coordinator.editorUndoManager.removeAllActions()
        }
    }

    /// Builds the composer's code box style, threading the configured chat
    /// font family through so the in-progress box matches the font the
    /// transcript's rendered code block uses once the message is submitted
    /// — see `MarkdownCodeBlockStyle.standard`'s doc comment.
    static func codeBlockStyle(
        theme: Theme,
        baseFont: NSFont,
        typography: ACPChatTypography
    ) -> MarkdownCodeBlockStyle {
        MarkdownCodeBlockStyle.standard(
            theme: theme,
            baseFont: baseFont,
            baseColor: .labelColor,
            monoSize: typography.codeSize,
            monoFontFamily: typography.fontFamily
        )
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
            dropRouter: dropRouter,
            upstreamReferences: upstreamReferences
        )
    }

    @MainActor
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
        private(set) var upstreamReferences: ACPUpstreamReferenceStore?
        private var upstreamObservations: Set<AnyCancellable> = []
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
        private var pendingScheduledSubmitIDs: Set<Int> = []
        var hasPendingNextPromptInput: Bool {
            pendingImageFileInsertions > 0 || pendingSubmitID != nil || !pendingScheduledSubmitIDs.isEmpty
        }
        var hasEmptyNextPromptDraft: Bool { lastSyncedDraft.isEmpty }
        private var pendingImageFileInsertions = 0
        private var imageFileInsertionGeneration = 0
        private var pendingRestyleWork: DispatchWorkItem?
        private var pendingRestyleGeneration = 0
        private var pendingRestyleRange: NSRange?
        var codeBlockStyle: MarkdownCodeBlockStyle?
        private var lastBlocks: [FencedBlock] = []
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
            dropRouter: ACPComposerDropRouter = ACPComposerDropRouter(),
            upstreamReferences: ACPUpstreamReferenceStore? = nil
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
            self.upstreamReferences = upstreamReferences
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
                let modifiers = NSApp.currentEvent?.modifierFlags ?? []
                // ⇧⏎ inserts a literal newline. (⌥⏎ never reaches here — it
                // routes to `insertNewlineIgnoringFieldEditor:` above. ⌘⏎ is
                // caught in ACPNSTextView.keyDown.)
                if modifiers.contains(.shift) {
                    textView.insertText("\n", replacementRange: textView.selectedRange())
                    return true
                }
                // Inside a code box ⏎ is a plain newline, so a multi-line
                // snippet doesn't need ⇧⏎ on every line. ⌘⏎ still sends.
                if let tv = textView as? ACPNSTextView,
                   tv.fencedBlockRange(containing: tv.selectedRange().location) != nil {
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
            // Block detection is a line-prefix scan, not a regex over the whole
            // document, so it is cheap enough to run synchronously here. Only
            // the attribute application stays on the debounce below.
            let blocks = MarkdownFenceEditing.blocks(in: storage.string)
            var dirty = ACPMarkdownLiveStyler.editedLineRange(in: storage)
            if let fenceDirty = ACPMarkdownLiveStyler.dirtyRange(
                previous: lastBlocks,
                current: blocks,
                storageLength: storage.length
            ) {
                dirty = dirty.map { NSUnionRange($0, fenceDirty) } ?? fenceDirty
            }
            lastBlocks = blocks
            pendingRestyleRange = pendingRestyleRange.map { existing in
                dirty.map { NSUnionRange(existing, $0) } ?? existing
            } ?? dirty
            pendingRestyleWork?.cancel()
            pendingRestyleGeneration += 1
            let generation = pendingRestyleGeneration
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                guard self.pendingRestyleGeneration == generation else { return }
                let blockRanges: [NSRange]
                if let style = self.codeBlockStyle {
                    blockRanges = MarkdownCodeBlockStyler
                        .restyle(storage, in: self.pendingRestyleRange, style: style)
                        .map(\.outerRange)
                } else {
                    blockRanges = []
                }
                ACPMarkdownLiveStyler.restyle(
                    storage,
                    in: self.pendingRestyleRange,
                    typography: self.typography,
                    excluding: blockRanges
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
            guard pendingScheduledSubmitIDs.isEmpty else { return }
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
                if case .schedule = intent {
                    pendingScheduledSubmitIDs.insert(submitID)
                }
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
            (textView as? ACPNSTextView)?.invalidateNextPromptSuggestion()
            pendingImageFileInsertions += 1
            if let tv = textView as? ACPNSTextView { tv.onNextPromptStateChange(tv.nextPromptInputState) }
            return imageFileInsertionGeneration
        }

        func finishPendingImageFileInsertion(generation: Int) {
            if generation == imageFileInsertionGeneration {
                pendingImageFileInsertions = max(0, pendingImageFileInsertions - 1)
                if let tv = textView as? ACPNSTextView { tv.onNextPromptStateChange(tv.nextPromptInputState) }
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
                tv.invalidateNextPromptSuggestion()
                tv.dismissSlashPanel()
                // Direct storage replacement below never routes through
                // `didChangeText`, so dismiss the hover preview here.
                tv.dismissImageChipHover()
            }
            invalidatePendingImageFileInsertions()
            restoringDraft = true
            storage.setAttributedString(Self.attributedString(from: draft, typography: typography))
            ACPLeadingCommand.chipify(storage, suggestions: promptSuggestions, font: typography.appKitFont())
            if let store = upstreamReferences, let host = store.hostKind {
                ACPUpstreamReferenceChip.chipify(storage, host: host, store: store)
            }
            // `restoringDraft` short-circuits `textDidChange`, where the fence
            // cache is normally refreshed, so refresh it here or it keeps
            // describing the document this one replaced.
            lastBlocks = MarkdownFenceEditing.blocks(in: storage.string)
            let blockRanges: [NSRange]
            if let style = codeBlockStyle {
                blockRanges = MarkdownCodeBlockStyler.restyle(storage, in: nil, style: style).map(\.outerRange)
            } else {
                blockRanges = []
            }
            ACPMarkdownLiveStyler.restyle(storage, typography: typography, excluding: blockRanges)
            textView.needsDisplay = true
            restoringDraft = false
            lastSyncedDraft = draft
        }

        /// Swaps the reference-chip store. Chips existing text once the
        /// remote resolves. `$remote` replays its current value, so an
        /// already-resolved store chips right away. Repaints chips whenever
        /// a lookup lands. Both hops go through the main queue so they never
        /// run nested inside another edit. Combine sink closures are
        /// nonisolated, so each hops back with `MainActor.assumeIsolated`,
        /// which holds because delivery is on `DispatchQueue.main`.
        func attachUpstreamReferences(_ store: ACPUpstreamReferenceStore?) {
            upstreamReferences = store
            upstreamObservations.removeAll()
            guard let store else { return }
            store.resolveRemote()
            store.$remote
                .compactMap { $0 }
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    MainActor.assumeIsolated {
                        (self?.textView as? ACPNSTextView)?.chipUpstreamReferencesIfNeeded()
                    }
                }
                .store(in: &upstreamObservations)
            store.$revision
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    MainActor.assumeIsolated { self?.textView?.needsDisplay = true }
                }
                .store(in: &upstreamObservations)
        }

        #if DEBUG
        /// Test seam: exposes the private restore path so tests can exercise
        /// direct storage replacement without a full submit cycle.
        func restoreDraftForTesting(_ draft: ACPComposerDraft, into textView: NSTextView) {
            restore(draft, into: textView)
        }
        #endif

        private func clearVisibleDraft(in textView: NSTextView) {
            if let tv = textView as? ACPNSTextView {
                tv.dismissSlashPanel()
                tv.dismissImageChipHover()
            }
            invalidatePendingImageFileInsertions()
            restoringDraft = true
            textView.string = ""
            // Same as `restore`: the cache has to follow the storage even when
            // `textDidChange` is short-circuited. An empty document has no
            // fenced blocks.
            lastBlocks = []
            textView.needsDisplay = true
            restoringDraft = false
        }

        private func finishSubmit(
            id: Int,
            draft: ACPComposerDraft,
            succeeded: Bool,
            textView: NSTextView?
        ) {
            let isCurrentSubmit = pendingSubmitID == id
            let isPendingSchedule = pendingScheduledSubmitIDs.remove(id) != nil
            guard isCurrentSubmit || isPendingSchedule else { return }
            if isCurrentSubmit {
                pendingSubmitID = nil
            }
            if succeeded {
                if isCurrentSubmit {
                    onDraftClear()
                }
            } else {
                let restoredDraft: ACPComposerDraft
                if isCurrentSubmit {
                    restoredDraft = draft
                } else if let textView {
                    restoredDraft = Self.draft(from: textView.attributedString()).appending(draft)
                } else {
                    restoredDraft = lastSyncedDraft.appending(draft)
                }
                onDraftChange(restoredDraft)
                if let textView {
                    restore(restoredDraft, into: textView)
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
                if keys.isComposerChip {
                    hasChip = true
                    stop.pointee = true
                }
            }
            if !hasChip {
                let text = attributed.string
                return ACPComposerDraft(segments: text.isEmpty ? [] : [.text(text)])
            }

            var segments: [ACPComposerDraft.Segment] = []
            // A command chip serializes to its `/command` text, merged with
            // neighbouring text so the draft matches its plain-text form.
            func appendText(_ text: String) {
                guard !text.isEmpty else { return }
                if case .text(let previous) = segments.last {
                    segments[segments.count - 1] = .text(previous + text)
                } else {
                    segments.append(.text(text))
                }
            }
            attributed.enumerateAttributes(in: full) { keys, range, _ in
                if let command = keys[.commandChipName] as? String {
                    appendText(command)
                } else if let spelling = keys[.upstreamReference] as? String {
                    appendText(spelling)
                } else if let uri = keys[.imageAttachmentURI] as? String {
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
                    appendText(attributed.attributedSubstring(from: range).string)
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
                if let command = keys[.commandChipName] as? String {
                    text += command
                } else if let spelling = keys[.upstreamReference] as? String {
                    text += spelling
                } else if let uri = keys[.imageAttachmentURI] as? String {
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

extension Dictionary where Key == NSAttributedString.Key, Value == Any {
    /// A composer chip run (mention, image, command, or upstream reference)
    /// that restyling must leave alone: resetting its attributes strips the
    /// attachment.
    var isComposerChip: Bool {
        self[.attachmentURI] != nil || self[.imageAttachmentURI] != nil
            || self[.commandChipName] != nil || self[.upstreamReference] != nil
    }
}

extension NSAttributedString.Key {
    static let attachmentURI = NSAttributedString.Key("alas.acp.attachmentURI")
    static let imageAttachmentURI = NSAttributedString.Key("alas.acp.imageAttachmentURI")
    static let imageAttachmentMime = NSAttributedString.Key("alas.acp.imageAttachmentMime")
}

final class ACPNSTextView: PairedDelimiterTextView {
    // Transient presentation only. The owner consumes the opportunity before insertion.
    var nextPromptOffer: String? {
        didSet {
            guard nextPromptOffer != oldValue else { return }
            refreshNextPromptLayout()
        }
    }
    var takeNextPromptOffer: () -> String? = { nil }
    var dismissNextPromptOffer: () -> Void = {}
    var onNextPromptStateChange: (NextPromptEligibilitySnapshot.Environment) -> Void = { _ in }
    var nextPromptDraftIsEmpty: () -> Bool = { true }
    var nextPromptInputBlocked: () -> Bool = { false }
    var nextPromptIsDictating: () -> Bool = { false }
    private var nextPromptInvalidationGeneration: UInt64 = 0
    private var insertingAcceptedNextPrompt = false
    private var imagePickerPresented = false
    private var dropPending = false

    var nextPromptInputState: NextPromptEligibilitySnapshot.Environment {
        var state = NextPromptEligibilitySnapshot.Environment()
        state.hasComposerFocus = window != nil && window?.firstResponder === self
        state.hasKeyWindow = window?.isKeyWindow == true
        state.hasSelection = selectedRanges.count != 1 || selectedRange() != NSRange(location: 0, length: 0)
        state.hasMarkedText = hasMarkedText()
        state.isDictating = nextPromptIsDictating() || dictationRange != nil || isApplyingDictationUpdate
        state.isPickerPresented = slashPanel != nil || mentionPanel != nil || imagePickerPresented
        state.hasPendingInput = dropPending || nextPromptInputBlocked() || coordinator?.hasPendingNextPromptInput == true
        return state
    }

    private var canShowNextPrompt: Bool {
        let state = nextPromptInputState
        guard isEditable, state.hasComposerFocus, state.hasKeyWindow, string.isEmpty, nextPromptDraftIsEmpty(),
              coordinator?.hasEmptyNextPromptDraft == true,
              !state.hasSelection, !state.hasMarkedText, !state.isDictating,
              !state.isPickerPresented, !state.hasPendingInput else { return false }
        return true
    }

    var nextPromptGhostText: String? {
        guard canShowNextPrompt, let nextPromptOffer, !nextPromptOffer.isEmpty else { return nil }
        return nextPromptOffer
    }

    var nextPromptPresentation: NSAttributedString? {
        guard let text = nextPromptGhostText else { return nil }
        let baseFont = font ?? chatTypography.appKitFont()
        let presentation = NSMutableAttributedString(string: text, attributes: [
            .font: NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        presentation.append(NSAttributedString(string: "\nTab to accept", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        return presentation
    }

    private var ghostHorizontalInset: CGFloat {
        textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0) + 1
    }

    func nextPromptHeight(for width: CGFloat) -> CGFloat {
        guard let presentation = nextPromptPresentation else { return 0 }
        let bounds = presentation.boundingRect(
            with: NSSize(width: max(1, width - 2 * ghostHorizontalInset), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return ceil(bounds.height) + 2 * textContainerInset.height
    }

    func composerContentHeight(for width: CGFloat) -> CGFloat {
        if let textContainer, let layoutManager {
            textContainer.containerSize.width = max(1, width - 2 * textContainerInset.width)
            layoutManager.ensureLayout(for: textContainer)
        }
        let editorHeight = textContainer.flatMap { layoutManager?.usedRect(for: $0).height } ?? 0
        return max(44, editorHeight + 2 * textContainerInset.height, nextPromptHeight(for: width))
    }

    func refreshNextPromptLayout() {
        needsDisplay = true
        invalidateIntrinsicContentSize()
        enclosingScrollView?.invalidateIntrinsicContentSize()
        if let scroll = enclosingScrollView {
            let width = scroll.contentSize.width
            super.setFrameSize(NSSize(width: width, height: max(scroll.contentSize.height, composerContentHeight(for: width))))
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(NSSize(width: newSize.width, height: max(newSize.height, nextPromptHeight(for: newSize.width))))
        if widthChanged { invalidateIntrinsicContentSize() }
        needsDisplay = true
    }

    @discardableResult
    func acceptNextPromptSuggestion() -> Bool {
        onNextPromptStateChange(nextPromptInputState)
        guard let displayed = nextPromptGhostText else { return false }
        let generation = nextPromptInvalidationGeneration
        guard let accepted = takeNextPromptOffer(), accepted == displayed else {
            invalidateNextPromptSuggestion()
            return false
        }
        nextPromptOffer = nil
        guard nextPromptInvalidationGeneration == generation, canShowNextPrompt else {
            invalidateNextPromptSuggestion()
            return false
        }
        insertingAcceptedNextPrompt = true
        defer { insertingAcceptedNextPrompt = false }
        breakUndoCoalescing()
        undoManager?.beginUndoGrouping()
        typingAttributes = baseTypingAttributes
        performNativeTextInsertion {
            insertText(accepted, replacementRange: selectedRange())
        }
        setSelectedRange(NSRange(location: accepted.utf16.count, length: 0))
        undoManager?.endUndoGrouping()
        breakUndoCoalescing()
        return true
    }

    func invalidateNextPromptSuggestion() {
        nextPromptInvalidationGeneration &+= 1
        nextPromptOffer = nil
        if !insertingAcceptedNextPrompt { dismissNextPromptOffer() }
    }

    override func accessibilityHelp() -> String? {
        guard let text = nextPromptGhostText else { return super.accessibilityHelp() }
        return "Suggestion: \(text) Press Tab or use Accept Suggestion to insert it."
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard nextPromptGhostText != nil else { return super.accessibilityCustomActions() }
        return [NSAccessibilityCustomAction(name: "Accept Suggestion") { [weak self] in
            self?.acceptNextPromptSuggestion() ?? false
        }]
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        invalidateNextPromptSuggestion()
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onNextPromptStateChange(nextPromptInputState)
    }

    override func unmarkText() {
        super.unmarkText()
        onNextPromptStateChange(nextPromptInputState)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        onNextPromptStateChange(nextPromptInputState)
        return result
    }

    override func resignFirstResponder() -> Bool {
        invalidateNextPromptSuggestion()
        let result = super.resignFirstResponder()
        var state = nextPromptInputState
        state.hasComposerFocus = false
        onNextPromptStateChange(state)
        return result
    }

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

    /// Whether a restyle has already run with a non-nil `markdownCodeBlockStyle`.
    ///
    /// `makeNSView` applies the typography and restores the persisted draft
    /// before `updateNSView` — the only place the code box style is handed
    /// over — has ever run, so on first mount both of those happen while the
    /// style is still nil. Without this the typography guard below would then
    /// swallow `updateNSView`'s own call (same typography, non-nil font) and a
    /// remounted draft's fenced block would stay unstyled until the user's next
    /// edit. One shot: once the style has been applied every later render
    /// re-enters the guard and returns, so SwiftUI updates do not each re-parse
    /// and re-attribute the whole storage.
    private var hasAppliedCodeBlockStyle = false

    func applyChatTypography(_ typography: ACPChatTypography) {
        let codeBlockStyleBecameAvailable = markdownCodeBlockStyle != nil && !hasAppliedCodeBlockStyle
        guard chatTypography != typography || font == nil || codeBlockStyleBecameAvailable else { return }
        chatTypography = typography
        font = typography.appKitFont()
        typingAttributes = baseTypingAttributes
        if let textStorage {
            var blockRanges: [NSRange] = []
            if let style = markdownCodeBlockStyle {
                blockRanges = MarkdownCodeBlockStyler
                    .restyle(textStorage, in: nil, style: style)
                    .map(\.outerRange)
                hasAppliedCodeBlockStyle = true
            }
            ACPMarkdownLiveStyler.restyle(
                textStorage,
                typography: typography,
                excluding: blockRanges
            )
        }
        refreshNextPromptLayout()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let font = font ?? chatTypography.appKitFont()
        if string.isEmpty {
            if let presentation = nextPromptPresentation {
                presentation.draw(
                    with: NSRect(x: ghostHorizontalInset, y: textContainerInset.height,
                                 width: max(1, bounds.width - 2 * ghostHorizontalInset),
                                 height: nextPromptHeight(for: bounds.width)),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]
                )
                return
            }
            guard !placeholderText.isEmpty else { return }
            let origin = NSPoint(
                x: textContainerInset.width + textContainer!.lineFragmentPadding + 1,
                y: textContainerInset.height
            )
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            (placeholderText as NSString).draw(at: origin, withAttributes: attrs)
            return
        }
        guard let hint = argumentGhostHint, let origin = endOfBufferGhostOrigin() else { return }
        // Dimmer than the empty-composer placeholder — this sits right next
        // to text the user just typed, so it reads as a faint suggestion
        // rather than competing with it. `tertiaryLabelColor` is the
        // system's own next step down from `secondaryLabelColor`, so it
        // keeps tracking dark/light mode and accessibility contrast
        // settings instead of a hand-picked alpha value.
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        (hint as NSString).draw(at: origin, withAttributes: attrs)
    }

    /// The slash command's argument hint (`input.hint` over ACP, e.g. a
    /// Claude skill's `argument-hint` frontmatter) to draw as ghost text
    /// after the caret, or nil when nothing should be shown.
    ///
    /// Recomputed from live state on every call — nothing is cached — so a
    /// stale ghost is impossible and a draft restored as exactly `/cmd ` on
    /// remount shows it with no extra bookkeeping. The ghost is only ever
    /// drawn (see `draw(_:)`), never inserted into the storage, so it can't
    /// be submitted, persisted as a draft, or restyled.
    var argumentGhostHint: String? {
        guard slashPanel == nil, let coord = coordinator, let textStorage else { return nil }
        return Self.argumentGhostHint(
            storage: textStorage,
            selection: selectedRange(),
            suggestions: coord.promptSuggestions
        )
    }

    /// The draft reads as exactly `/cmd ` with the caret at the end, whether
    /// the command is plain text or a leading command chip.
    static func argumentGhostHint(
        storage: NSAttributedString,
        selection: NSRange,
        suggestions: [ACPPromptSuggestion]
    ) -> String? {
        let length = storage.length
        guard length > 0, selection.length == 0, selection.location == length else { return nil }
        let text: String
        if let command = storage.attribute(.commandChipName, at: 0, effectiveRange: nil) as? String {
            guard length == 2, (storage.string as NSString).character(at: 1) == 0x20 else { return nil }
            text = command + " "
        } else {
            text = storage.string
        }
        guard text.hasPrefix("/"),
              let suggestion = suggestions.first(where: { text == $0.command + " " }),
              let hint = suggestion.hint, !hint.isEmpty
        else { return nil }
        return hint
    }

    /// View-space top-left for text drawn right after the last glyph, on
    /// its line. Computed from the layout manager rather than
    /// `firstRect(forCharacterRange:)`, which answers in screen coordinates.
    private func endOfBufferGhostOrigin() -> NSPoint? {
        guard let layoutManager, let textContainer else { return nil }
        let glyphCount = layoutManager.numberOfGlyphs
        guard glyphCount > 0 else { return nil }
        let lastGlyph = NSRange(location: glyphCount - 1, length: 1)
        let line = layoutManager.lineFragmentRect(forGlyphAt: lastGlyph.location, effectiveRange: nil)
        let glyph = layoutManager.boundingRect(forGlyphRange: lastGlyph, in: textContainer)
        return NSPoint(
            x: glyph.maxX + textContainerOrigin.x,
            y: line.minY + textContainerOrigin.y
        )
    }

    /// Caret moves without text edits don't fire `didChangeText`, and the
    /// ghost hint depends on the selection, so force a repaint here.
    /// `setSelectedRanges(_:affinity:stillSelecting:)` is the primitive
    /// method NSTextView funnels every other selection-setting call
    /// through (mouse clicks, arrow keys, `setSelectedRange`), so this
    /// catches all of them.
    override func setSelectedRanges(
        _ ranges: [NSValue],
        affinity: NSSelectionAffinity,
        stillSelecting stillSelectingFlag: Bool
    ) {
        invalidateNextPromptSuggestion()
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag)
        onNextPromptStateChange(nextPromptInputState)
        needsDisplay = true
    }

    override func didChangeText() {
        invalidateNextPromptSuggestion()
        super.didChangeText()
        onNextPromptStateChange(nextPromptInputState)
        // Trigger placeholder redraw when text becomes (non-)empty.
        needsDisplay = true
        // An edit moves or destroys the chip under the cursor — close the
        // hover popover so it can't linger at a stale anchor.
        dismissImageChipHover()
        // A manual edit while a dictation span is open (typing elsewhere,
        // pasting) leaves the underlying speech session mid-utterance —
        // it keeps analyzing and will emit more corrections for that same
        // utterance, unaware the user just took over. Untracking the span
        // alone stops those corrections from overwriting the wrong
        // characters, but not from landing at all: the analyzer's next
        // "corrected" hypothesis would still be inserted as a fresh span,
        // duplicating whatever partial text it already committed. Stopping
        // dictation outright is what actually prevents that — the partial
        // transcript already applied stays as ordinary editable text, and
        // nothing more arrives to duplicate it.
        //
        // `replaceDictationRegion` sets `isApplyingDictationUpdate` around
        // its own edit so this doesn't fire in response to dictation's own
        // writes.
        if dictationRange != nil, !isApplyingDictationUpdate {
            dictationRange = nil
            coordinator?.onStopDictation()
        }
    }

    /// Any edit invalidates a pending next-prompt ghost-text offer, then
    /// intercepts the single whitespace character that completes a
    /// hand-typed leading command, turning it into a pill in the SAME edit
    /// as the keystroke instead of a follow-up one — see
    /// `ACPLeadingCommand.chipTarget(completingWith:at:in:suggestions:)` for
    /// why a follow-up edit is unsafe here. Also completes a hand-typed
    /// upstream reference (`#12`, etc.) the same way. Everything else
    /// (fenced-block pairing, IME composition, plain typing) still goes
    /// through `PairedDelimiterTextView`'s own `insertText`.
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        invalidateNextPromptSuggestion()
        let range = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
        if let text = insertString as? String,
           let textStorage, let coordinator,
           let target = ACPLeadingCommand.chipTarget(
               completingWith: text, at: range, in: textStorage,
               suggestions: coordinator.promptSuggestions
           ) {
            let chip = NSMutableAttributedString(
                attributedString: ACPLeadingCommand.chip(for: target.command, font: chatTypography.appKitFont())
            )
            chip.append(NSAttributedString(string: text, attributes: baseTypingAttributes))
            replaceClearingUndo(range: target.range, with: chip)
            return
        }
        if let text = insertString as? String,
           let target = upstreamReferenceChipTarget(completing: text, at: range) {
            // Same single-edit, undo-clearing path as the command pill; see
            // `replaceClearingUndo` for why a follow-up edit is unsafe.
            replaceClearingUndo(range: target.range, with: target.replacement)
            return
        }
        super.insertText(insertString, replacementRange: replacementRange)
    }

    /// A draft restored, or (re)assigned wholesale, before the agent listed
    /// its commands gets its pill once the list arrives — possibly after the
    /// user already typed `/command ` as plain text with its own undo
    /// history. Safe to call from SwiftUI's `updateNSView` — never nested
    /// inside another edit, unlike the reentrancy the `insertText` override
    /// above guards against.
    func pillLeadingCommandIfNeeded() {
        guard let textStorage, let coordinator,
              let target = ACPLeadingCommand.chipTarget(in: textStorage, suggestions: coordinator.promptSuggestions)
        else { return }
        let chip = ACPLeadingCommand.chip(for: target.command, font: chatTypography.appKitFont())
        replaceClearingUndo(range: target.range, with: chip)
    }

    /// Replaces `range` with `replacement`, deliberately WITHOUT registering
    /// an undo action.
    ///
    /// This transformation only ever runs once the plain-text command
    /// already sitting in storage is complete — right as the user finishes
    /// typing it, or once a late `available_commands_update` recognizes it —
    /// so there is always a PRE-EXISTING undo record from the typing that
    /// put that text there. Every attempt to also make this specific edit
    /// undoable (`shouldChangeText`/`didChangeText`'s automatic rich-text
    /// synthesis, a manually registered inverse, breaking typing-coalescing
    /// first, bracketing it in its own undo group, reordering it against
    /// `didChangeText()`) still corrupted that earlier record when the user
    /// undid afterward — `NSTextStorage` throws `NSRangeException` out of an
    /// internal post-edit attribute-fixing pass, reproducibly, regardless of
    /// mechanism. Clearing the undo stack here is the one option that is
    /// actually safe: it costs the user one step of undo history (the
    /// letters they just typed collapse into a pill they can no longer type
    /// back out via Cmd-Z; deleting the chip and retyping still works), in
    /// exchange for never risking a crash. The chip still round-trips to
    /// identical plain text for drafts, queued prompts, and the outgoing
    /// message — only interactive undo of this specific transformation is
    /// given up.
    func replaceClearingUndo(range: NSRange, with replacement: NSAttributedString) {
        guard let textStorage else { return }
        let selectionBefore = selectedRange()
        undoManager?.removeAllActions()
        textStorage.replaceCharacters(in: range, with: replacement)
        let replacedRange = NSRange(location: range.location, length: replacement.length)
        // `didChangeText()` must run before the selection is touched — it's
        // what tells the layout manager the storage changed shape, and
        // reading/writing the selection first operates against layout that
        // still describes the pre-edit text. Mutating `textStorage` directly
        // bypasses `NSTextView`'s own selection bookkeeping, so the
        // selection must be clamped back into range explicitly here too.
        didChangeText()
        // Preserve the selection outside the command rather than always
        // collapsing it to a caret right after the chip: a late
        // `available_commands_update` can land while the user has kept
        // typing past the command, has a selection past it, or simply left
        // their caret sitting before it (`/init body` with the caret still
        // at position 0) — forcing any of those to jump to right after the
        // pill would yank the user's cursor out from under them. Each
        // endpoint maps independently: at or after the replaced range, it
        // survives shifted by the length delta; at or before its start —
        // ONLY for a zero-length caret, which touches none of the
        // command's own characters — it's untouched, since nothing before
        // the edit moved; anywhere else was inside the text the chip just
        // replaced and has nowhere sensible to land but the chip's end
        // (also where the typed-completion path above always finds its
        // caret, since typing the completing space puts it exactly at the
        // command's end).
        let delta = replacement.length - range.length
        let rangeEnd = NSMaxRange(range)
        let isEmptySelection = selectionBefore.length == 0
        func map(_ location: Int) -> Int {
            if location >= rangeEnd { return location + delta }
            if isEmptySelection, location <= range.location { return location }
            return NSMaxRange(replacedRange)
        }
        let newStart = map(selectionBefore.location)
        let newEnd = map(NSMaxRange(selectionBefore))
        setSelectedRange(NSRange(location: newStart, length: newEnd - newStart))
    }

    /// Retry-once-on-attach: a restored draft can already contain an active
    /// "/" token before this view is attached to a window — `positionAndShow`
    /// needs the window to place the panel, so `reconcileSlashPanel` is a
    /// no-op until attachment. Also (re)installs the scroll bounds observer
    /// used by the image chip hover preview.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        invalidateNextPromptSuggestion()
        onNextPromptStateChange(nextPromptInputState)
        if window != nil {
            reconcileSlashPanel()
        }
        refreshScrollBoundsObserver()
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
        dismissImageChipHover()
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
                // Only without Command. ⌘⏎ is a send, not an accept, and this
                // branch runs first — so swallowing it here would make the
                // picker the one state where ⌘⏎ does not reach the send
                // handler below.
                if !event.modifierFlags.contains(.command),
                   let pick = panel.model.selected() {
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

        if !hasMarkedText(), mentionPanel == nil,
           event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty {
            if event.keyCode == 48, acceptNextPromptSuggestion() { return }
            if event.keyCode == 53, nextPromptGhostText != nil {
                invalidateNextPromptSuggestion()
                return
            }
        }
        invalidateNextPromptSuggestion()

        // ⌘⏎ always sends, including from inside a code box where bare ⏎ is a
        // newline. Handled here rather than in `doCommandBy` because AppKit
        // does not reliably route Command-Return to `insertNewline:`.
        if event.keyCode == 36 || event.keyCode == 76,
           event.modifierFlags.contains(.command) {
            coordinator?.submit(self, intent: .auto)
            return
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
        if openUpstreamReference(at: convert(event.locationInWindow, from: nil), event: event) { return }
        invalidateNextPromptSuggestion()
        super.mouseDown(with: event)
        reconcileSlashPanel()
    }

    private func presentMentionPopover() {
        invalidateNextPromptSuggestion()
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
        onNextPromptStateChange(nextPromptInputState)
        positionAndShow(panel)
    }

    private func closeMentionPanel() {
        mentionPanel?.close()
        mentionPanel = nil
        mentionStart = -1
        onNextPromptStateChange(nextPromptInputState)
    }

    /// Locate an active `/<word>` token at the caret. Active means: the
    /// `/` starts at the beginning of the buffer or right after
    /// whitespace, and everything between it and the caret is
    /// command-shaped (letters / digits / `-` / `_` / `:` / `$`, the last
    /// for skills some agents list as `/$name`). Returns the
    /// `/`'s character index and the current query (without the slash).
    private func currentSlashToken() -> (start: Int, query: String)? {
        let str = (string as NSString)
        let caret = selectedRange().location
        guard caret <= str.length else { return nil }
        var i = caret
        let allowed: Set<Character> = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_:$")
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
        invalidateNextPromptSuggestion()
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
        onNextPromptStateChange(nextPromptInputState)
        positionAndShow(panel, makeKey: false)
    }

    private func closeSlashPanel() {
        slashPanel?.close()
        slashPanel = nil
        slashStart = -1
        onNextPromptStateChange(nextPromptInputState)
    }

    /// Public hooks used by the coordinator's `doCommandBy:` fallback so
    /// the Esc / `cancelOperation:` selector can dismiss the panel
    /// without reaching across private state.
    var isSlashPanelOpen: Bool { slashPanel != nil }
    func dismissSlashPanel() { closeSlashPanel() }

    var worktreeIdForStaging: String {
        coordinator?.worktreeRoot.lastPathComponent ?? "default"
    }

    // MARK: - Image chip hover preview

    private var imageChipHover: ACPImageChipHoverController?
    private let commandChipHover = ACPCommandChipHoverController()
    private let upstreamReferenceHover = ACPUpstreamReferenceHoverController()

    /// Character range + file URL when `point` sits on an image chip
    /// (a character tagged with `.imageAttachmentURI`), nil otherwise.
    /// `location` clamps to the container length, which is what the layout
    /// manager answers for glyph-range lookups.
    func imageChipRange(at point: NSPoint) -> (range: NSRange, fileURL: URL)? {
        guard let hit = chipHit(at: point, key: .imageAttachmentURI),
              let uri = hit.value as? String,
              let fileURL = URL(string: uri) else { return nil }
        return (range: hit.range, fileURL: fileURL)
    }

    /// Range + suggestion when `point` sits on a leading command chip.
    func commandChipHit(at point: NSPoint) -> (range: NSRange, suggestion: ACPPromptSuggestion)? {
        guard let hit = chipHit(at: point, key: .commandChipName),
              let command = hit.value as? String,
              let suggestion = coordinator?.promptSuggestions.first(where: { $0.command == command })
        else { return nil }
        return (range: hit.range, suggestion: suggestion)
    }

    private func chipHit(at point: NSPoint, key: NSAttributedString.Key) -> (range: NSRange, value: Any)? {
        guard let layoutManager, let textContainer, let textStorage, textStorage.length > 0 else { return nil }
        // Convert from view space (includes textContainerInset) to container
        // space first, matching how the layout manager maps points to glyphs.
        let containerPoint = NSPoint(
            x: point.x - textContainerInset.width,
            y: point.y - textContainerInset.height
        )
        var fraction: CGFloat = 0
        let characterIndex = layoutManager.characterIndex(
            for: containerPoint,
            in: textContainer,
            fractionOfDistanceBetweenInsertionPoints: &fraction
        )
        guard characterIndex != NSNotFound, characterIndex < textStorage.length else { return nil }
        var chipRange = NSRange()
        guard let value = textStorage.attribute(key, at: characterIndex, effectiveRange: &chipRange)
        else { return nil }
        // The nearest-character lookup can resolve a character even when the
        // point is in blank space beside a glyph (e.g. after an end-of-line
        // chip) — require the chip's glyph rect to actually contain the point.
        let glyphRange = layoutManager.glyphRange(forCharacterRange: chipRange, actualCharacterRange: nil)
        guard glyphRange.length > 0 else { return nil }
        let glyphRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        guard glyphRect.contains(containerPoint) else { return nil }
        return (range: chipRange, value: value)
    }

    /// View-space rect of the chip's glyphs (inset 1pt, mirroring the cell
    /// draw) for anchoring the hover popover.
    func imageChipAnchorRect(for range: NSRange) -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }
        guard range.location < (string as NSString).length else { return nil }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphRange.length > 0 else { return nil }
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        return rect.insetBy(dx: 1, dy: 1)
    }

    /// Hover preview size cap: the visible composer width when attached to
    /// a window, otherwise the layout's default content width. Never a floor
    /// — a narrow composer narrows the preview with it.
    static func imageChipPreviewCap(in textView: ACPNSTextView) -> NSSize? {
        let width: CGFloat
        if textView.window != nil, textView.visibleRect.width > 0 {
            width = textView.visibleRect.width
        } else {
            width = ACPChatLayout.defaultContentMaxWidth
        }
        let screenHeight = NSScreen.main?.frame.height ?? 900
        return NSSize(width: width, height: screenHeight / 2)
    }

    /// Identifies our hover tracking area across `updateTrackingAreas`
    /// rebuilds without touching areas other code may have added.
    private static let hoverTrackingAreaKind = "alas.acp.imageChipHover"

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Remove only our hover area, matched by userInfo; areas registered
        // by other owners stay untouched.
        for area in trackingAreas
        where area.owner === self && area.userInfo?[Self.hoverTrackingAreaKind] != nil {
            removeTrackingArea(area)
        }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self,
                userInfo: [Self.hoverTrackingAreaKind: true]
            )
        )
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        if let chip = imageChipRange(at: point) {
            imageChipHoverController().scheduleShow(range: chip.range, fileURL: chip.fileURL, in: self)
        } else {
            imageChipHoverController().hide()
        }
        if let chip = commandChipHit(at: point) {
            commandChipHover.scheduleShow(range: chip.range, suggestion: chip.suggestion, in: self)
        } else {
            commandChipHover.hide()
        }
        upstreamReferenceHover.update(at: point, in: self, store: coordinator?.upstreamReferences)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        imageChipHoverController().hide()
        commandChipHover.hide()
        upstreamReferenceHover.hide()
    }

    /// Observes the enclosing scroll view's clip view while the composer is
    /// in a window. A scroll moves content under a stationary pointer without
    /// any `mouseMoved`/`mouseExited`, so without this a pending or visible
    /// hover preview could anchor to (or show) content that is no longer
    /// under the pointer. The dismiss re-checks the pointer position so
    /// hovering a chip across a scroll tick re-schedules instead of flickering.
    private var scrollBoundsObserver: (any NSObjectProtocol)?

    private func refreshScrollBoundsObserver() {
        if let scrollBoundsObserver {
            NotificationCenter.default.removeObserver(scrollBoundsObserver)
            self.scrollBoundsObserver = nil
        }
        guard let clipView = enclosingScrollView?.contentView else { return }
        clipView.postsBoundsChangedNotifications = true
        scrollBoundsObserver = NotificationCenter.default.addMainActorObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView
        ) { [weak self] in
            guard let self, self.window != nil else { return }
            self.commandChipHover.hide()
            self.upstreamReferenceHover.hide()
            // The pointer's current position decides the post-scroll state:
            // still over a chip re-schedules (no-op while it stays there);
            // anywhere else hides. `window.mouseLocationOutsideOfEventStream`
            // is valid without an in-flight mouse event.
            let point = self.convert(self.window!.mouseLocationOutsideOfEventStream, from: nil)
            if let chip = self.imageChipRange(at: point) {
                self.imageChipHoverController().scheduleShow(range: chip.range, fileURL: chip.fileURL, in: self)
            } else {
                self.imageChipHoverController().hide()
            }
        }
    }

    private func teardownScrollBoundsObserver() {
        if let scrollBoundsObserver {
            NotificationCenter.default.removeObserver(scrollBoundsObserver)
            self.scrollBoundsObserver = nil
        }
    }

    isolated deinit {
        teardownScrollBoundsObserver()
    }

    private func imageChipHoverController() -> ACPImageChipHoverController {
        if let imageChipHover { return imageChipHover }
        #if DEBUG
        let controller = imageChipHoverSpy ?? ACPImageChipHoverController()
        #else
        let controller = ACPImageChipHoverController()
        #endif
        imageChipHover = controller
        return controller
    }

    #if DEBUG
    /// Test seam: substitutes a spy controller for the real one so tests
    /// can observe dismissal without building real popovers.
    var imageChipHoverSpy: ACPImageChipHoverController?
    #endif

    /// Closes the hover popover (if showing) — called on edits, so the
    /// preview can never linger over a chip the user just changed.
    func dismissImageChipHover() {
        imageChipHover?.hide()
        commandChipHover.hide()
        upstreamReferenceHover.hide()
    }

    #if DEBUG
    /// Test seam: schedules a hover show exactly as `mouseMoved` would.
    func scheduleImageChipHoverForTesting(range: NSRange, fileURL: URL) {
        imageChipHoverController().scheduleShow(range: range, fileURL: fileURL, in: self)
    }

    /// Test seam: count of pending (uncancelled) show work items.
    var pendingImageChipHoverCountForTesting: Int {
        imageChipHover?.hasPendingShowForTesting == true ? 1 : 0
    }

    /// Test seam: routes a draft through the coordinator's private restore
    /// path (direct `NSTextStorage` replacement, no `didChangeText`).
    func restoreDraftForTesting(_ draft: ACPComposerDraft) {
        coordinator?.restoreDraftForTesting(draft, into: self)
    }
    #endif

    static let maxImagesPerMessage = 10

    /// Counts image-attachment CHARACTERS, not attribute runs: two adjacent
    /// image chips sharing the same content-addressed URI (the same file
    /// pasted twice with no text between them) have equal `.imageAttachmentURI`
    /// string values, and `enumerateAttribute` coalesces equal adjacent
    /// values into a single run — undercounting them as one chip instead of
    /// two, and letting the message grow past `maxImagesPerMessage`.
    private func imageChipCount(in range: NSRange) -> Int {
        guard let storage = textStorage, range.length > 0 else { return 0 }
        var count = 0
        for index in range.location..<NSMaxRange(range) {
            if storage.attribute(.imageAttachmentURI, at: index, effectiveRange: nil) != nil {
                count += 1
            }
        }
        return count
    }

    private func currentImageChipCount() -> Int {
        guard let storage = textStorage else { return 0 }
        return imageChipCount(in: NSRange(location: 0, length: storage.length))
    }

    @discardableResult
    func insertImage(data: Data, worktreeId: String) -> Bool {
        insertImage(data: data, worktreeId: worktreeId, replacementRange: selectedRange())
    }

    @discardableResult
    private func insertImage(data: Data, worktreeId: String, replacementRange: NSRange) -> Bool {
        invalidateNextPromptSuggestion()
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
        invalidateNextPromptSuggestion()
        imagePickerPresented = true
        onNextPromptStateChange(nextPromptInputState)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP]
        panel.begin { [weak self] response in
            guard let self else { return }
            self.imagePickerPresented = false
            self.onNextPromptStateChange(self.nextPromptInputState)
            guard response == .OK else { return }
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
            if let gate = ACPNSTextView.imageFileReadGateForTesting {
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
        invalidateNextPromptSuggestion()
        if insertComposerDraft(from: NSPasteboard.general) { return }
        if insertImages(from: NSPasteboard.general) { return }
        if let text = NSPasteboard.general.string(forType: .string) {
            insertPlainText(text)
            return
        }
        super.paste(sender)
    }

    // MARK: Chip-preserving copy / paste

    /// Private pasteboard type carrying a composer selection as a JSON,
    /// MAC-authenticated payload, so chips keep their identity across copy,
    /// cut, paste, and drag within the app. Written alongside a readable
    /// `.string` form for every other destination.
    static let composerDraftPasteboardType = NSPasteboard.PasteboardType("io.alas.acp.composer-draft")

    /// Generated once per process launch and NEVER serialized anywhere,
    /// including the pasteboard payload itself. NSPasteboard has no
    /// per-app read protection — any unsandboxed process on the machine can
    /// publish the exact same named pasteboard type — so decoding untrusted
    /// JSON there as trusted composer state would let a forged payload
    /// point an `.image` or `.mention` chip's URI at an arbitrary local
    /// file the user never picked, which submission then reads or forwards
    /// to the agent. An earlier version of this fix put a bearer token
    /// inside the payload it authenticated, which any application reading
    /// one legitimate copy could scrape and replay in a forgery. Signing
    /// with an HMAC keyed by a secret that never leaves the process closes
    /// that: forging a valid signature for chosen content requires the key
    /// itself, not just an observed (content, signature) pair.
    private static let pasteboardMACKey = SymmetricKey(size: .bits256)

    private struct AuthenticatedDraftPayload: Codable {
        let draftJSON: Data
        /// The pasteboard's own `changeCount` at the moment this payload was
        /// written, folded into the signed bytes. HMAC integrity alone
        /// stops tampering but not replay: another application that
        /// observed one legitimate (draftJSON, mac) pair could republish it
        /// later — unchanged content, still a valid signature — paired with
        /// deceptive bait text in `.string`, tricking the user into pasting
        /// a stale chip they don't expect. `NSPasteboard.changeCount` bumps
        /// on every `declareTypes`/`clearContents` call to ANY pasteboard
        /// content, ours or an attacker's, so a payload is only ever valid
        /// against the exact write that produced it — PROVIDED it's also
        /// checked against the pasteboard that write actually happened on;
        /// see `trustedPasteboardWrites`, which closes the gap a bare
        /// integer comparison leaves (a change count is only unique per
        /// pasteboard OBJECT, not globally, and another process can pump an
        /// unrelated pasteboard — e.g. a drag pasteboard — to any small
        /// target count cheaply).
        let changeCount: Int
        let mac: Data
    }

    /// Tracks, per pasteboard OBJECT (keyed by identity, not by name/type —
    /// `NSPasteboard.general` is a shared singleton, but a drag session's
    /// pasteboard is a fresh object each time), the change count established
    /// by OUR most recent write to it. `changeCount` alone only proves "this
    /// pasteboard's current count equals this number" — trivial for another
    /// process to fake by declaring types on its OWN pasteboard repeatedly
    /// until its independent counter reaches a leaked value, then
    /// publishing our captured (draftJSON, mac) bytes there. Requiring the
    /// specific pasteboard OBJECT we wrote to also be the one being read
    /// from closes that: an attacker's own pasteboard, however they tune
    /// its count, was never in this table.
    ///
    /// The dictionary value RETAINS the pasteboard itself, not just its
    /// `ObjectIdentifier` — an identifier is only unique for the lifetime of
    /// the object it names, and once that object deallocates, a later,
    /// entirely unrelated `NSPasteboard` (an attacker's own, say) can be
    /// allocated at the same freed address and collide with a stale
    /// identifier still sitting in this table. Holding a strong reference
    /// keeps every tracked pasteboard alive for the rest of the process, so
    /// its address can never be reused while its entry exists. Entries
    /// accumulate for the process's lifetime — bounded by how many times
    /// the user actually copies/drags a chip in a session, not worth adding
    /// eviction for.
    private static var trustedPasteboardWrites: [ObjectIdentifier: (pasteboard: NSPasteboard, changeCount: Int)] = [:]

    /// Signs `draft`'s JSON encoding, bound to `changeCount`, with the
    /// process-local MAC key, and records `pboard` as the one this specific
    /// signature is valid against.
    private static func signedDraftPayload(_ draft: ACPComposerDraft, changeCount: Int, writtenTo pboard: NSPasteboard) -> Data? {
        guard let draftJSON = try? JSONEncoder().encode(draft) else { return nil }
        var signedBytes = draftJSON
        withUnsafeBytes(of: changeCount) { signedBytes.append(contentsOf: $0) }
        let mac = HMAC<SHA256>.authenticationCode(for: signedBytes, using: pasteboardMACKey)
        trustedPasteboardWrites[ObjectIdentifier(pboard)] = (pboard, changeCount)
        return try? JSONEncoder().encode(
            AuthenticatedDraftPayload(draftJSON: draftJSON, changeCount: changeCount, mac: Data(mac))
        )
    }

    /// Verifies and decodes a payload written by `signedDraftPayload`,
    /// rejecting it unless `pboard`'s CURRENT change count still matches the
    /// one it was signed against AND `pboard` is the exact object that
    /// signature was recorded against — see `AuthenticatedDraftPayload` and
    /// `trustedPasteboardWrites`. Returns nil for anything else, including a
    /// well-formed JSON draft with no signature, which is exactly what a
    /// forged pasteboard payload from another application looks like.
    private static func verifiedDraft(from data: Data, on pboard: NSPasteboard) -> ACPComposerDraft? {
        guard let payload = try? JSONDecoder().decode(AuthenticatedDraftPayload.self, from: data),
              payload.changeCount == pboard.changeCount,
              let trusted = trustedPasteboardWrites[ObjectIdentifier(pboard)],
              trusted.pasteboard === pboard,
              trusted.changeCount == payload.changeCount
        else { return nil }
        var signedBytes = payload.draftJSON
        withUnsafeBytes(of: payload.changeCount) { signedBytes.append(contentsOf: $0) }
        guard HMAC<SHA256>.isValidAuthenticationCode(payload.mac, authenticating: signedBytes, using: pasteboardMACKey)
        else { return nil }
        return try? JSONDecoder().decode(ACPComposerDraft.self, from: payload.draftJSON)
    }

    /// The single selected range as a draft, when it contains at least one
    /// chip. Chip-free selections return nil and keep NSTextView's own
    /// pasteboard behavior.
    private var selectedChipDraft: ACPComposerDraft? {
        guard selectedRanges.count == 1, let textStorage else { return nil }
        let range = selectedRange()
        guard range.length > 0, NSMaxRange(range) <= textStorage.length else { return nil }
        let fragment = textStorage.attributedSubstring(from: range)
        var hasChip = false
        fragment.enumerateAttributes(in: NSRange(location: 0, length: fragment.length)) { keys, _, stop in
            if keys.isComposerChip {
                hasChip = true
                stop.pointee = true
            }
        }
        return hasChip ? ACPInputField.Coordinator.draft(from: fragment) : nil
    }

    /// A chip is a U+FFFC attachment character, so NSTextView's own
    /// `.string` representation of it is that placeholder. Selections with
    /// chips write the chips' text form instead (`/command`, `@filename`),
    /// plus the private, MAC-authenticated draft type so a paste back into
    /// a composer restores the chips themselves.
    ///
    /// Deliberately does NOT gate on `types.contains(.string)`: NSTextView's
    /// own `writablePasteboardTypes` is not a reliable signal of what a
    /// caller actually wants written — it can report an empty array
    /// (observed outside a full interactive AppKit session, e.g. under a
    /// test host) while `super.writeSelection` still populates `.string`
    /// regardless of the `types` it was given. Requiring `.string` to
    /// appear in that array made this override silently never run in
    /// exactly that situation.
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let draft = selectedChipDraft else { return super.writeSelection(to: pboard, types: types) }
        // declareTypes both establishes ownership and returns the new
        // change count in one call, so the count that ends up signed is
        // exactly the one this write produces — nothing else can race it
        // in between, since setData/setString below don't bump it further.
        let changeCount = pboard.declareTypes([Self.composerDraftPasteboardType, .string], owner: nil)
        guard let data = Self.signedDraftPayload(draft, changeCount: changeCount, writtenTo: pboard) else {
            return super.writeSelection(to: pboard, types: types)
        }
        pboard.setData(data, forType: Self.composerDraftPasteboardType)
        pboard.setString(draft.plainText, forType: .string)
        return true
    }

    #if DEBUG
    /// Test seam: writes a draft to `pboard` through the same
    /// MAC-authenticated, change-count-bound payload `writeSelection`
    /// produces, so tests can exercise `readSelection`/`paste` without
    /// reaching into the private key that guards against pasteboard
    /// forgery.
    static func writeComposerDraftForTesting(_ draft: ACPComposerDraft, to pboard: NSPasteboard) {
        let changeCount = pboard.declareTypes([composerDraftPasteboardType, .string], owner: nil)
        let data = signedDraftPayload(draft, changeCount: changeCount, writtenTo: pboard)!
        pboard.setData(data, forType: composerDraftPasteboardType)
        pboard.setString(draft.plainText, forType: .string)
    }

    /// Test seam: publishes onto `pboard` a payload that is byte-for-byte
    /// valid (correct MAC, matching `pboard`'s CURRENT change count) but was
    /// signed and recorded against a different pasteboard entirely — i.e.
    /// exactly what an attacker gets by declaring types on their OWN
    /// pasteboard until its independent counter reaches a number leaked
    /// from a legitimate copy, then republishing the captured bytes on the
    /// pasteboard the composer actually reads from (e.g. a drag session's).
    static func writeReplayedSignedDraftForTesting(_ draft: ACPComposerDraft, onto pboard: NSPasteboard) {
        let targetCount = pboard.declareTypes([composerDraftPasteboardType, .string], owner: nil)
        let scratch = NSPasteboard(name: .init("alas-replay-source-\(UUID().uuidString)"))
        defer { scratch.releaseGlobally() }
        var scratchCount = scratch.declareTypes([composerDraftPasteboardType], owner: nil)
        while scratchCount < targetCount {
            scratchCount = scratch.declareTypes([composerDraftPasteboardType], owner: nil)
        }
        precondition(scratchCount == targetCount, "test setup could not align pasteboard change counts")
        let data = signedDraftPayload(draft, changeCount: targetCount, writtenTo: scratch)!
        pboard.setData(data, forType: composerDraftPasteboardType)
        pboard.setString(draft.plainText, forType: .string)
    }
    #endif

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [Self.composerDraftPasteboardType] + super.readablePasteboardTypes
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if type == Self.composerDraftPasteboardType, insertComposerDraft(from: pboard) { return true }
        return super.readSelection(from: pboard, type: type)
    }

    /// Drops `.image` segments once the message would exceed
    /// `maxImagesPerMessage`, reporting the same `.tooManyImages` error the
    /// normal image-insertion path does. Without this, repeatedly
    /// copy/pasting a draft that carries an image chip would recreate the
    /// attachment directly and bypass the cap `insertImage` enforces.
    /// `replacementRange` is excluded from the existing count: those images
    /// are about to be removed by this same edit, not kept alongside it.
    ///
    /// An `.image` whose staged file no longer exists is skipped WITHOUT
    /// charging it against the budget: `attributedString(from:)` is going to
    /// drop it anyway, so charging it here would waste a slot on nothing,
    /// causing a real image later in the same draft to be rejected as
    /// overflow even though it would have fit.
    private func capImages(in draft: ACPComposerDraft, replacementRange: NSRange) -> ACPComposerDraft {
        let existing = currentImageChipCount() - imageChipCount(in: replacementRange)
        var budget = Self.maxImagesPerMessage - existing
        var overflowed = false
        let segments = draft.segments.filter { segment in
            guard case .image(let uri, _) = segment else { return true }
            guard let fileURL = URL(string: uri), FileManager.default.fileExists(atPath: fileURL.path) else {
                return false
            }
            guard budget > 0 else {
                overflowed = true
                return false
            }
            budget -= 1
            return true
        }
        if overflowed {
            coordinator?.reportImageError(.tooManyImages)
        }
        return ACPComposerDraft(segments: segments)
    }

    /// Inserts a copied composer selection over the current selection with
    /// its chips rebuilt. A leading `/command` pasted at the very start of
    /// the message becomes a pill again, in the same edit as the paste,
    /// under the same rule as a hand-typed one: it has to be followed by
    /// whitespace, from the pasted text or the text already after it.
    ///
    /// Only accepts the payload when its MAC verifies against this
    /// process's own key AND `pboard`'s change count still matches the one
    /// it was signed against — see `pasteboardMACKey` and
    /// `AuthenticatedDraftPayload.changeCount` — so neither a payload forged
    /// by another application (the pasteboard type name is not
    /// access-controlled) nor a stale, replayed one from an earlier
    /// legitimate copy is ever trusted as composer state; `paste(_:)` falls
    /// back to that application's plain, readable `.string` instead.
    @discardableResult
    private func insertComposerDraft(from pboard: NSPasteboard) -> Bool {
        guard let data = pboard.data(forType: Self.composerDraftPasteboardType),
              let decoded = Self.verifiedDraft(from: data, on: pboard),
              !decoded.isEmpty,
              let textStorage
        else { return false }
        let replacementRange = boundedSelectedRange(in: textStorage)
        let draft = capImages(in: decoded, replacementRange: replacementRange)
        // The whole draft was one or more images already at the cap: the
        // error was reported, and there's nothing left to insert, but the
        // paste itself was still handled — falling through would let
        // `paste(_:)` retry with the general pasteboard's plain-text form.
        guard !draft.isEmpty else { return true }
        let fragment = NSMutableAttributedString(
            attributedString: ACPInputField.Coordinator.attributedString(from: draft, typography: chatTypography)
        )
        // `draft` was structurally non-empty (it has an `.image` segment),
        // but `attributedString(from:)` silently drops an `.image` whose
        // staged file no longer exists on disk — and a copied image chip
        // commonly has a trailing separator space next to it (`insertImage`
        // always appends one), which survives as ordinary text even when
        // the image itself is dropped. Either way, once every chip is gone,
        // what's left is whitespace with nothing (a U+FFFC character isn't
        // whitespace, so a surviving chip always fails this check): inserting
        // it would delete a nonempty selection and leave an orphan space
        // behind instead of the paste the user expected. Treat this the same
        // as the all-images-capped case: handled, nothing to insert.
        guard !fragment.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        if replacementRange.location == 0, let coordinator {
            let tail = NSMaxRange(replacementRange)
            let combined = NSMutableAttributedString(attributedString: fragment)
            combined.append(textStorage.attributedSubstring(
                from: NSRange(location: tail, length: textStorage.length - tail)
            ))
            if let target = ACPLeadingCommand.chipTarget(in: combined, suggestions: coordinator.promptSuggestions),
               NSMaxRange(target.range) <= fragment.length {
                fragment.replaceCharacters(
                    in: target.range,
                    with: ACPLeadingCommand.chip(for: target.command, font: chatTypography.appKitFont())
                )
            }
        }
        chipUpstreamReferences(in: fragment, replacing: replacementRange)
        let attrs = baseTypingAttributes
        typingAttributes = attrs
        performNativeTextInsertion {
            insertText(fragment, replacementRange: replacementRange)
        }
        typingAttributes = attrs
        return true
    }

    private func boundedSelectedRange(in textStorage: NSTextStorage) -> NSRange {
        let range = selectedRange()
        let location = min(range.location, textStorage.length)
        return NSRange(location: location, length: min(range.length, textStorage.length - location))
    }

    @discardableResult
    func insertPlainText(_ text: String) -> Bool {
        guard let textStorage else { return false }
        let boundedRange = boundedSelectedRange(in: textStorage)
        let attrs = baseTypingAttributes
        typingAttributes = attrs
        let fragment = NSMutableAttributedString(string: text, attributes: attrs)
        let chipped = chipUpstreamReferences(in: fragment, replacing: boundedRange)
        performNativeTextInsertion {
            // Plain strings keep going through the String path so paired
            // delimiter handling is unchanged when nothing was chipped.
            if chipped {
                insertText(fragment, replacementRange: boundedRange)
            } else {
                insertText(text, replacementRange: boundedRange)
            }
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
        invalidateNextPromptSuggestion()
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
        onNextPromptStateChange(nextPromptInputState)
        return true
    }

    /// Stops tracking the live dictation span without altering the
    /// committed text — used when dictation is toggled off mid-utterance.
    func cancelDictationRegion() {
        dictationRange = nil
        onNextPromptStateChange(nextPromptInputState)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        invalidateNextPromptSuggestion()
        dropPending = true
        onNextPromptStateChange(nextPromptInputState)
        return hasImage(in: sender.draggingPasteboard) ? .copy : super.draggingEntered(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        dropPending = false
        onNextPromptStateChange(nextPromptInputState)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        invalidateNextPromptSuggestion()
        defer {
            dropPending = false
            onNextPromptStateChange(nextPromptInputState)
        }
        if insertImages(from: sender.draggingPasteboard) { return true }
        return super.performDragOperation(sender)
    }

    @discardableResult
    func insertMention(_ url: URL) -> Bool {
        invalidateNextPromptSuggestion()
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
        guard slashStart >= 0, caret >= slashStart else {
            ts.append(NSAttributedString(string: replacement))
            closeSlashPanel()
            didChangeText()
            return
        }
        let range = NSRange(location: slashStart, length: caret - slashStart)
        // Captured before `closeSlashPanel()`, which resets `slashStart`.
        let isLeadingCommand = slashStart == 0
        closeSlashPanel()
        // A leading command is what the agent will actually run, so only
        // that one becomes a pill; mid-message picks stay plain text. The
        // picked token can be several characters longer than its one-glyph
        // chip (e.g. accepting `/read-jira-ticket` while `/read-j` is still
        // live) — the same shrinking edit `replaceClearingUndo` exists for,
        // so the leading branch goes through it too instead of a direct
        // `replaceCharacters` that would leave this keystroke's own typing
        // undo record targeting a range that no longer exists.
        if isLeadingCommand {
            let chip = NSMutableAttributedString(
                attributedString: ACPLeadingCommand.chip(for: suggestion.command, font: chatTypography.appKitFont())
            )
            chip.append(NSAttributedString(string: " ", attributes: baseTypingAttributes))
            replaceClearingUndo(range: range, with: chip)
        } else {
            ts.replaceCharacters(in: range, with: NSAttributedString(string: replacement, attributes: baseTypingAttributes))
            // `range.location`, not `slashStart` — `closeSlashPanel()` above
            // already reset `slashStart` to -1.
            setSelectedRange(NSRange(location: range.location + (replacement as NSString).length, length: 0))
            didChangeText()
        }
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
