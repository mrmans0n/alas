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
}
