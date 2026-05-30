import AppKit
import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACP composer draft bridge")
struct ACPComposerDraftBridgeTests {
    @Test("accepted submit restores structured draft when async completion fails")
    func acceptedSubmitRestoresDraftWhenCompletionFails() {
        let draft = ACPComposerDraft(segments: [
            .text("Read "),
            .mention(displayName: "File.swift", uri: "file:///tmp/File.swift"),
            .text(" before replying")
        ])
        let textView = NSTextView()
        textView.textStorage?.setAttributedString(ACPInputField.Coordinator.attributedString(from: draft))
        var changedDrafts: [ACPComposerDraft] = []
        var clearCount = 0
        var completion: (@MainActor (Bool) -> Void)?

        let coordinator = ACPInputField.Coordinator(
            worktreeRoot: URL(fileURLWithPath: "/tmp"),
            initialDraft: .empty,
            sendOnEnter: true,
            onDraftChange: { changedDrafts.append($0) },
            onDraftClear: { clearCount += 1 },
            onSubmit: { _, _, _, submittedDraft, onFinished in
                #expect(submittedDraft == draft)
                completion = onFinished
                return true
            }
        )
        coordinator.textView = textView

        coordinator.submit(textView, intent: .auto)
        #expect(textView.string.isEmpty)
        #expect(changedDrafts.isEmpty)
        #expect(clearCount == 0)

        completion?(false)

        #expect(changedDrafts == [draft])
        #expect(clearCount == 0)
        #expect(ACPInputField.Coordinator.draft(from: textView.attributedString()) == draft)
    }

    @Test("accepted submit clears persisted draft when async completion succeeds")
    func acceptedSubmitClearsDraftWhenCompletionSucceeds() {
        let draft = ACPComposerDraft(segments: [.text("hello")])
        let textView = NSTextView()
        textView.textStorage?.setAttributedString(ACPInputField.Coordinator.attributedString(from: draft))
        var changedDrafts: [ACPComposerDraft] = []
        var clearCount = 0
        var completion: (@MainActor (Bool) -> Void)?

        let coordinator = ACPInputField.Coordinator(
            worktreeRoot: URL(fileURLWithPath: "/tmp"),
            initialDraft: .empty,
            sendOnEnter: true,
            onDraftChange: { changedDrafts.append($0) },
            onDraftClear: { clearCount += 1 },
            onSubmit: { _, _, _, submittedDraft, onFinished in
                #expect(submittedDraft == draft)
                completion = onFinished
                return true
            }
        )
        coordinator.textView = textView

        coordinator.submit(textView)
        completion?(true)

        #expect(changedDrafts.isEmpty)
        #expect(clearCount == 1)
        #expect(textView.string.isEmpty)
    }

    @Test("submit flushes pending draft before accepting")
    func submitFlushesPendingDraftBeforeAccepting() {
        let draft = ACPComposerDraft(segments: [.text("hello")])
        let textView = NSTextView()
        textView.string = "hello"
        var events: [String] = []

        let coordinator = ACPInputField.Coordinator(
            worktreeRoot: URL(fileURLWithPath: "/tmp"),
            initialDraft: .empty,
            sendOnEnter: true,
            onDraftChange: {
                #expect($0 == draft)
                events.append("draft")
            },
            onDraftClear: { events.append("clear") },
            onSubmit: { _, _, _, submittedDraft, _ in
                #expect(submittedDraft == draft)
                events.append("submit")
                return true
            }
        )
        coordinator.textView = textView

        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        #expect(events == ["draft"])
        coordinator.submit(textView)

        #expect(events == ["draft", "submit"])
    }

    @Test("flushed pending restyle does not publish again after visible draft clears")
    func flushedPendingRestyleDoesNotPublishAgainAfterVisibleDraftClears() async throws {
        let draft = ACPComposerDraft(segments: [.text("hello")])
        let textView = NSTextView()
        textView.string = "hello"
        var changedDrafts: [ACPComposerDraft] = []
        var completion: (@MainActor (Bool) -> Void)?

        let coordinator = ACPInputField.Coordinator(
            worktreeRoot: URL(fileURLWithPath: "/tmp"),
            initialDraft: .empty,
            sendOnEnter: true,
            onDraftChange: { changedDrafts.append($0) },
            onDraftClear: {},
            onSubmit: { _, _, _, _, onFinished in
                completion = onFinished
                return true
            }
        )
        coordinator.textView = textView

        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        coordinator.flushPendingRestyleNow()
        coordinator.submit(textView)
        completion?(true)
        try await Task.sleep(nanoseconds: 650_000_000)

        #expect(changedDrafts == [draft])
    }

    @Test("debounced restyle includes every line dirtied during the debounce")
    func debouncedRestyleIncludesEveryDirtyLine() {
        let textView = NSTextView()
        textView.string = "one\ntwo"
        let coordinator = ACPInputField.Coordinator(
            worktreeRoot: URL(fileURLWithPath: "/tmp"),
            initialDraft: .empty,
            sendOnEnter: true,
            onDraftChange: { _ in },
            onDraftClear: {},
            onSubmit: { _, _, _, _, _ in true }
        )
        coordinator.textView = textView

        textView.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 3), with: "**one**")
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        textView.textStorage?.replaceCharacters(in: NSRange(location: 8, length: 3), with: "**two**")
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        coordinator.flushPendingRestyleNow()

        let attributed = textView.attributedString()
        let firstFont = attributed.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        let secondFont = attributed.attribute(.font, at: 10, effectiveRange: nil) as? NSFont
        #expect(firstFont?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(secondFont?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    }

    @Test("successful completion does not clear newer draft after intervening edit")
    func successfulCompletionDoesNotClearNewerDraftAfterInterveningEdit() {
        let submittedDraft = ACPComposerDraft(segments: [.text("hello")])
        let newerDraft = ACPComposerDraft(segments: [
            .text("new "),
            .mention(displayName: "File.swift", uri: "file:///tmp/File.swift")
        ])
        let textView = NSTextView()
        textView.textStorage?.setAttributedString(ACPInputField.Coordinator.attributedString(from: submittedDraft))
        var changedDrafts: [ACPComposerDraft] = []
        var clearCount = 0
        var completion: (@MainActor (Bool) -> Void)?

        let coordinator = ACPInputField.Coordinator(
            worktreeRoot: URL(fileURLWithPath: "/tmp"),
            initialDraft: .empty,
            sendOnEnter: true,
            onDraftChange: { changedDrafts.append($0) },
            onDraftClear: { clearCount += 1 },
            onSubmit: { _, _, _, draft, onFinished in
                #expect(draft == submittedDraft)
                completion = onFinished
                return true
            }
        )
        coordinator.textView = textView

        coordinator.submit(textView)
        textView.textStorage?.setAttributedString(ACPInputField.Coordinator.attributedString(from: newerDraft))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        coordinator.flushPendingRestyleNow()
        completion?(true)

        #expect(changedDrafts == [newerDraft])
        #expect(clearCount == 0)
        #expect(ACPInputField.Coordinator.draft(from: textView.attributedString()) == newerDraft)
    }

    @Test("failed completion does not restore submitted draft after intervening edit")
    func failedCompletionDoesNotRestoreSubmittedDraftAfterInterveningEdit() {
        let submittedDraft = ACPComposerDraft(segments: [.text("hello")])
        let newerDraft = ACPComposerDraft(segments: [
            .text("new "),
            .mention(displayName: "File.swift", uri: "file:///tmp/File.swift")
        ])
        let textView = NSTextView()
        textView.textStorage?.setAttributedString(ACPInputField.Coordinator.attributedString(from: submittedDraft))
        var changedDrafts: [ACPComposerDraft] = []
        var clearCount = 0
        var completion: (@MainActor (Bool) -> Void)?

        let coordinator = ACPInputField.Coordinator(
            worktreeRoot: URL(fileURLWithPath: "/tmp"),
            initialDraft: .empty,
            sendOnEnter: true,
            onDraftChange: { changedDrafts.append($0) },
            onDraftClear: { clearCount += 1 },
            onSubmit: { _, _, _, draft, onFinished in
                #expect(draft == submittedDraft)
                completion = onFinished
                return true
            }
        )
        coordinator.textView = textView

        coordinator.submit(textView)
        textView.textStorage?.setAttributedString(ACPInputField.Coordinator.attributedString(from: newerDraft))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        coordinator.flushPendingRestyleNow()
        completion?(false)

        #expect(changedDrafts == [newerDraft])
        #expect(clearCount == 0)
        #expect(ACPInputField.Coordinator.draft(from: textView.attributedString()) == newerDraft)
    }

    @Test("persisted draft sync clears a remounted submitted draft")
    func persistedDraftSyncClearsRemountedSubmittedDraft() {
        let submittedDraft = ACPComposerDraft(segments: [.text("already sent")])
        let textView = NSTextView()
        textView.textStorage?.setAttributedString(ACPInputField.Coordinator.attributedString(from: submittedDraft))
        var changedDrafts: [ACPComposerDraft] = []
        var clearCount = 0

        let coordinator = ACPInputField.Coordinator(
            worktreeRoot: URL(fileURLWithPath: "/tmp"),
            initialDraft: submittedDraft,
            sendOnEnter: true,
            onDraftChange: { changedDrafts.append($0) },
            onDraftClear: { clearCount += 1 },
            onSubmit: { _, _, _, _, _ in true }
        )

        coordinator.syncPersistedDraft(.empty, into: textView)

        #expect(ACPInputField.Coordinator.draft(from: textView.attributedString()) == .empty)
        #expect(changedDrafts.isEmpty)
        #expect(clearCount == 0)
    }

    @Test("persisted draft sync does not overwrite unsynced local edits")
    func persistedDraftSyncDoesNotOverwriteUnsyncedLocalEdits() {
        let submittedDraft = ACPComposerDraft(segments: [.text("already sent")])
        let localDraft = ACPComposerDraft(segments: [.text("still typing")])
        let textView = NSTextView()
        textView.textStorage?.setAttributedString(ACPInputField.Coordinator.attributedString(from: localDraft))
        var changedDrafts: [ACPComposerDraft] = []
        var clearCount = 0

        let coordinator = ACPInputField.Coordinator(
            worktreeRoot: URL(fileURLWithPath: "/tmp"),
            initialDraft: submittedDraft,
            sendOnEnter: true,
            onDraftChange: { changedDrafts.append($0) },
            onDraftClear: { clearCount += 1 },
            onSubmit: { _, _, _, _, _ in true }
        )

        coordinator.syncPersistedDraft(.empty, into: textView)

        #expect(ACPInputField.Coordinator.draft(from: textView.attributedString()) == localDraft)
        #expect(changedDrafts.isEmpty)
        #expect(clearCount == 0)
    }

    @Test("toolbar send button bypasses keyboard inversion (sendOnEnter=false)")
    func toolbarSubmitBypassesInversion() {
        // Regression: the inversion was previously applied to ALL submits
        // upstream of the composer, including the toolbar send button.
        // With `acpSendOnEnter = false`, a plain ↑ click would have been
        // converted to `.steer` (cancel + discard) instead of `.auto`
        // (queue/send). The fix moves the keyboard inversion INTO the
        // coordinator's `doCommandBy`; `submit(_:intent:)` (which the
        // button calls via `actions.submitWithIntent`) emits the intent
        // verbatim.
        let textView = NSTextView()
        textView.string = "hello"
        var received: ACPSubmitIntent?
        let coordinator = ACPInputField.Coordinator(
            worktreeRoot: URL(fileURLWithPath: "/tmp"),
            initialDraft: .empty,
            sendOnEnter: false,           // user inverted the setting
            onDraftChange: { _ in },
            onDraftClear: {},
            onSubmit: { _, _, intent, _, _ in
                received = intent
                return true
            }
        )
        coordinator.textView = textView

        coordinator.submit(textView, intent: .auto)
        #expect(received == .auto)        // NOT inverted by the button path
    }

    @Test("serializes plain text and mention chips in order")
    func serializesAttributedDraft() {
        let attributed = NSMutableAttributedString(string: "Read ")
        let attachment = ACPMentionChipAttachment(displayName: "File.swift", uri: "file:///tmp/File.swift")
        let chip = NSMutableAttributedString(attachment: attachment)
        chip.addAttributes([
            .attachmentURI: "file:///tmp/File.swift",
            .toolTip: "/tmp/File.swift",
        ], range: NSRange(location: 0, length: chip.length))
        attributed.append(chip)
        attributed.append(NSAttributedString(string: " now"))

        let draft = ACPInputField.Coordinator.draft(from: attributed)

        #expect(draft == ACPComposerDraft(segments: [
            .text("Read "),
            .mention(displayName: "File.swift", uri: "file:///tmp/File.swift"),
            .text(" now")
        ]))
    }

    @Test("restores mention chips from draft")
    func restoresAttributedDraft() {
        let draft = ACPComposerDraft(segments: [
            .text("Read "),
            .mention(displayName: "File.swift", uri: "file:///tmp/File.swift"),
            .text(" now")
        ])

        let attributed = ACPInputField.Coordinator.attributedString(from: draft)
        let serialized = ACPInputField.Coordinator.draft(from: attributed)

        #expect(serialized == draft)
    }

    // MARK: - Keyboard intent resolution (doCommandBy)

    private func makeCoordinator(
        sendOnEnter: Bool,
        onSubmit: @escaping ACPComposerSubmitHandler
    ) -> ACPInputField.Coordinator {
        ACPInputField.Coordinator(
            worktreeRoot: URL(fileURLWithPath: "/tmp"),
            initialDraft: .empty,
            sendOnEnter: sendOnEnter,
            onDraftChange: { _ in },
            onDraftClear: {},
            onSubmit: onSubmit
        )
    }

    @Test("⌥⏎ (insertNewlineIgnoringFieldEditor:) submits with .steer")
    func optionReturnSteers() {
        // AppKit routes ⌥⏎ to `insertNewlineIgnoringFieldEditor:`, NOT
        // `insertNewline:` — so the handler must catch it explicitly or
        // the keystroke falls through to a literal newline (the bug).
        let textView = NSTextView()
        textView.string = "redirect the agent"
        var received: ACPSubmitIntent?
        var submittedText: String?
        let coordinator = makeCoordinator(sendOnEnter: true) { text, _, intent, _, _ in
            submittedText = text
            received = intent
            return true
        }
        coordinator.textView = textView

        let handled = coordinator.textView(
            textView,
            doCommandBy: #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
        )

        #expect(handled)                              // event swallowed (no literal newline)
        #expect(received == .steer)
        // The exact composer contents are submitted — no stray "\n" appended.
        #expect(submittedText == "redirect the agent")
    }

    @Test("⌥⏎ inverts to .auto when sendOnEnter is off")
    func optionReturnInvertsWhenSendOnEnterOff() {
        let textView = NSTextView()
        textView.string = "redirect the agent"
        var received: ACPSubmitIntent?
        let coordinator = makeCoordinator(sendOnEnter: false) { _, _, intent, _, _ in
            received = intent
            return true
        }
        coordinator.textView = textView

        _ = coordinator.textView(
            textView,
            doCommandBy: #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
        )

        #expect(received == .auto)
    }

    @Test("plain ⏎ (insertNewline:) submits with .auto")
    func plainReturnAuto() {
        let textView = NSTextView()
        textView.string = "send this"
        var received: ACPSubmitIntent?
        let coordinator = makeCoordinator(sendOnEnter: true) { _, _, intent, _, _ in
            received = intent
            return true
        }
        coordinator.textView = textView

        let handled = coordinator.textView(
            textView,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        )

        #expect(handled)
        #expect(received == .auto)
    }

    @Test("plain ⏎ inverts to .steer when sendOnEnter is off")
    func plainReturnInvertsWhenSendOnEnterOff() {
        let textView = NSTextView()
        textView.string = "send this"
        var received: ACPSubmitIntent?
        let coordinator = makeCoordinator(sendOnEnter: false) { _, _, intent, _, _ in
            received = intent
            return true
        }
        coordinator.textView = textView

        _ = coordinator.textView(
            textView,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        )

        #expect(received == .steer)
    }

    // MARK: - Restoring a queued item into the composer (blocks → draft)

    @Test("draft from content blocks maps text and resource links")
    func draftFromBlocks() {
        let blocks: [ACPContentBlock] = [
            .text("look at "),
            .resourceLink(uri: "file:///tmp/File.swift", name: "File.swift"),
            .text(" please"),
        ]

        #expect(ACPComposerDraft(blocks: blocks) == ACPComposerDraft(segments: [
            .text("look at "),
            .mention(displayName: "File.swift", uri: "file:///tmp/File.swift"),
            .text(" please"),
        ]))
    }

    @Test("resource link without a name falls back to its last path component")
    func resourceLinkWithoutName() {
        #expect(ACPComposerDraft(blocks: [
            .resourceLink(uri: "file:///tmp/File.swift", name: nil),
        ]) == ACPComposerDraft(segments: [
            .mention(displayName: "File.swift", uri: "file:///tmp/File.swift"),
        ]))
    }

    @Test("image block becomes a mention chip carrying its uri")
    func imageBlockBecomesMention() {
        #expect(ACPComposerDraft(blocks: [
            .image(uri: "file:///tmp/shot.png", mimeType: "image/png"),
        ]) == ACPComposerDraft(segments: [
            .mention(displayName: "shot.png", uri: "file:///tmp/shot.png"),
        ]))
    }

    @Test("appending onto an empty draft yields the other draft")
    func appendingOntoEmpty() {
        let queued = ACPComposerDraft(segments: [.text("queued message")])
        #expect(ACPComposerDraft.empty.appending(queued) == queued)
    }

    @Test("appending an empty draft is a no-op")
    func appendingEmpty() {
        let typed = ACPComposerDraft(segments: [.text("typed")])
        #expect(typed.appending(.empty) == typed)
    }

    @Test("appending two non-empty drafts joins them with a newline")
    func appendingTwoNonEmpty() {
        let typed = ACPComposerDraft(segments: [.text("typed")])
        let queued = ACPComposerDraft(segments: [.text("queued")])

        #expect(typed.appending(queued) == ACPComposerDraft(segments: [
            .text("typed"),
            .text("\n"),
            .text("queued"),
        ]))
    }
}
