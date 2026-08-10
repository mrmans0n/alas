import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Alas

@MainActor
@Suite("ACP composer draft bridge")
struct ACPComposerDraftBridgeTests {
    @Test("dismantling the composer clears stale AppKit undo actions")
    func dismantlingComposerClearsUndoActions() {
        let textView = ACPNSTextView()
        textView.allowsUndo = true
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        let undoOwner = ACPTestUndoOwner()
        textView.delegate = undoOwner
        let coordinator = makeCoordinator(sendOnEnter: true) { _, _, _, _, _ in true }

        textView.undoManager?.registerUndo(withTarget: textView) { _ in }
        #expect(textView.undoManager?.canUndo == true)

        ACPInputField.dismantleNSView(scrollView, coordinator: coordinator)

        #expect(textView.undoManager?.canUndo == false)
    }

    @Test("editing lifecycle updates composer focus binding")
    func editingLifecycleUpdatesFocusBinding() {
        var focused = false
        let coordinator = ACPInputField.Coordinator(
            worktreeRoot: URL(fileURLWithPath: "/tmp"),
            initialDraft: .empty,
            isFocused: Binding(
                get: { focused },
                set: { focused = $0 }
            ),
            focusRequest: 0,
            sendOnEnter: true,
            onDraftChange: { _ in },
            onDraftClear: {},
            onSubmit: { _, _, _, _, _ in true }
        )

        coordinator.textDidBeginEditing(Notification(name: NSText.didBeginEditingNotification))
        #expect(focused)

        coordinator.textDidEndEditing(Notification(name: NSText.didEndEditingNotification))
        #expect(!focused)
    }

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
            focusRequest: 0,
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
            focusRequest: 0,
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
            focusRequest: 0,
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
            focusRequest: 0,
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
            focusRequest: 0,
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
            focusRequest: 0,
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
            focusRequest: 0,
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
            focusRequest: 0,
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
            focusRequest: 0,
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
            focusRequest: 0,
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

    @Test("mention insertion replaces the typed trigger and restores base typing attributes")
    func mentionInsertionReplacesTriggerAndRestoresTypingAttributes() {
        let textView = ACPNSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        textView.textStorage?.setAttributedString(NSAttributedString(string: "@"))
        textView.setSelectedRange(NSRange(location: 1, length: 0))

        let inserted = textView.insertMention(URL(fileURLWithPath: "/tmp/File.swift"))

        #expect(inserted)
        #expect(!textView.string.contains("@"))
        #expect(ACPInputField.Coordinator.draft(from: textView.attributedString()) == ACPComposerDraft(segments: [
            .mention(displayName: "File.swift", uri: "file:///tmp/File.swift"),
            .text(" "),
        ]))
        #expect(textView.selectedRange() == NSRange(location: textView.attributedString().length, length: 0))

        let trailingSpaceIndex = textView.attributedString().length - 1
        let trailingColor = textView.attributedString().attribute(
            .foregroundColor,
            at: trailingSpaceIndex,
            effectiveRange: nil
        ) as? NSColor
        let typingColor = textView.typingAttributes[.foregroundColor] as? NSColor

        #expect(trailingColor == NSColor.labelColor)
        #expect(typingColor == NSColor.labelColor)
    }

    @Test("mention chip frame centers on surrounding text")
    func mentionChipFrameCentersOnText() throws {
        let font = NSFont.systemFont(ofSize: 13)
        let attachment = ACPMentionChipAttachment(displayName: "build.yml", uri: "file:///tmp/build.yml")
        let storage = NSTextStorage(string: "x", attributes: [.font: font])
        let chip = NSMutableAttributedString(attachment: attachment)
        chip.addAttributes([.font: font], range: NSRange(location: 0, length: chip.length))
        storage.append(chip)
        storage.append(NSAttributedString(string: "y", attributes: [.font: font]))

        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: 200, height: 100))
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)

        let frame = try #require(attachment.attachmentCell).cellFrame(
            for: textContainer,
            proposedLineFragment: NSRect(x: 0, y: 0, width: 200, height: 20),
            glyphPosition: NSPoint(x: 12, y: 30),
            characterIndex: 1
        )

        let textCenter = (font.ascender + font.descender) / 2
        #expect(abs(frame.midY - textCenter) < 0.001)
        #expect(frame.minY < -4)
    }

    @Test("slash panel closes when filtering has no command matches")
    func slashPanelClosesWhenFilteringHasNoMatches() {
        let (textView, coordinator, window) = makeSlashTextView()
        _ = (coordinator, window)
        textView.string = "/"
        textView.setSelectedRange(NSRange(location: 1, length: 0))

        textView.reconcileSlashPanel()
        #expect(textView.isSlashPanelOpen)

        textView.string = "/zz"
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        textView.reconcileSlashPanel()

        #expect(!textView.isSlashPanelOpen)
    }

    @Test("slash panel closes when input is cleared outside keyDown")
    func slashPanelClosesWhenInputIsClearedOutsideKeyDown() {
        let (textView, coordinator, window) = makeSlashTextView()
        _ = (coordinator, window)
        textView.string = "/"
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        textView.reconcileSlashPanel()
        #expect(textView.isSlashPanelOpen)

        textView.string = ""
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.reconcileSlashPanel()

        #expect(!textView.isSlashPanelOpen)
    }

    @Test("slash panel closes when composer editing ends")
    func slashPanelClosesOnEditingEnd() {
        let (textView, coordinator, window) = makeSlashTextView()
        _ = window
        textView.string = "/"
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        textView.reconcileSlashPanel()
        #expect(textView.isSlashPanelOpen)

        coordinator.textDidEndEditing(
            Notification(name: NSText.didEndEditingNotification, object: textView)
        )

        #expect(!textView.isSlashPanelOpen)
    }

    @Test("plain paste insertion normalizes inherited rich text styling")
    func plainPasteInsertionNormalizesRichTextStyling() throws {
        let textView = ACPNSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        let source = NSMutableAttributedString(
            string: "before after",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        textView.textStorage?.setAttributedString(source)
        textView.setSelectedRange(NSRange(location: 7, length: 0))
        textView.typingAttributes = [
            .font: NSFont.systemFont(ofSize: 48),
            .foregroundColor: NSColor.black,
        ]

        let inserted = textView.insertPlainText("RICH")

        #expect(inserted)
        #expect(textView.string == "before RICHafter")
        let insertedRange = NSRange(location: 7, length: 4)
        try assertComposerBaseStyle(in: textView.attributedString(), range: insertedRange)
        #expect((textView.typingAttributes[.foregroundColor] as? NSColor) == NSColor.labelColor)
        let typingFont = try #require(textView.typingAttributes[.font] as? NSFont)
        #expect(typingFont.pointSize == 13)
    }

    @Test("plain paste insertion replaces selected text with normalized styling")
    func plainPasteInsertionReplacesSelectionWithNormalizedStyling() throws {
        let textView = ACPNSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        textView.textStorage?.setAttributedString(NSAttributedString(
            string: "replace me",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor,
            ]
        ))
        textView.setSelectedRange(NSRange(location: 0, length: 7))

        let inserted = textView.insertPlainText("keep")

        #expect(inserted)
        #expect(textView.string == "keep me")
        #expect(textView.selectedRange() == NSRange(location: 4, length: 0))
        try assertComposerBaseStyle(in: textView.attributedString(), range: NSRange(location: 0, length: 4))
    }

    @Test("paste with unsupported file URL falls back to plain text")
    func pasteWithUnsupportedFileURLFallsBackToPlainText() throws {
        let textView = ACPNSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("alas-paste-\(UUID().uuidString).txt")
        try "not an image".write(to: temp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: temp) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([temp as NSURL])
        NSPasteboard.general.setString("fallback text", forType: .string)

        textView.paste(nil)

        #expect(textView.string == "fallback text")
    }

    @Test("paste with oversized image file URL reports image error")
    func pasteWithOversizedImageFileURLReportsImageError() async throws {
        let textView = ACPNSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        let coordinator = makeCoordinator(sendOnEnter: true) { _, _, _, _, _ in true }
        let reported = ACPImageErrorRecorder()
        coordinator.onImageError = { error in
            Task { await reported.append(error) }
        }
        textView.coordinator = coordinator
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("alas-paste-\(UUID().uuidString).png")
        var bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        bytes.append(Data(repeating: 0, count: ACPImageStaging.maxBytes + 1))
        try bytes.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([temp as NSURL])
        NSPasteboard.general.setString("fallback text", forType: .string)

        textView.paste(nil)
        try await Task.sleep(nanoseconds: 100_000_000)
        let errors = await reported.snapshot()

        #expect(errors == [.tooLarge])
        #expect(textView.string.isEmpty)
    }

    @Test("async image paste does not replace stale selection after edit")
    func asyncImagePasteDoesNotReplaceStaleSelectionAfterEdit() async throws {
        let textView = ACPNSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("alas-paste-\(UUID().uuidString).png")
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        let gate = ACPImageReadGate()
        ACPNSTextView.imageFileReadGateForTesting = { await gate.wait() }
        defer { ACPNSTextView.imageFileReadGateForTesting = nil }
        textView.string = "replace me"
        textView.setSelectedRange(NSRange(location: 0, length: 7))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([temp as NSURL])

        textView.paste(nil)
        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
        _ = textView.insertPlainText("!")
        await gate.open()
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(textView.string.hasPrefix("replace me!"))
        #expect(textView.string.contains("\u{fffc}"))
    }

    @Test("submit waits while async image file paste is pending")
    func submitWaitsWhileAsyncImageFilePasteIsPending() async throws {
        let textView = ACPNSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        var submitCount = 0
        var submittedAttachments: [ACPMessage.Attachment] = []
        let coordinator = makeCoordinator(sendOnEnter: true) { _, attachments, _, _, _ in
            submitCount += 1
            submittedAttachments = attachments
            return true
        }
        textView.coordinator = coordinator
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("alas-paste-\(UUID().uuidString).png")
        try pngBytes.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        let gate = ACPImageReadGate()
        ACPNSTextView.imageFileReadGateForTesting = { await gate.wait() }
        defer { ACPNSTextView.imageFileReadGateForTesting = nil }
        textView.string = "describe "
        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([temp as NSURL])

        textView.paste(nil)
        coordinator.submit(textView)
        #expect(submitCount == 0)

        await gate.open()
        for _ in 0..<20 where (try imageAttachmentData(in: textView)).isEmpty {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        coordinator.submit(textView)

        #expect(submitCount == 1)
        #expect(submittedAttachments.count == 1)
    }

    @Test("async image paste is discarded after draft is cleared")
    func asyncImagePasteIsDiscardedAfterDraftIsCleared() async throws {
        let textView = ACPNSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        let coordinator = makeCoordinator(sendOnEnter: true) { _, _, _, _, _ in true }
        textView.coordinator = coordinator
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("alas-paste-\(UUID().uuidString).png")
        try pngBytes.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        let gate = ACPImageReadGate()
        ACPNSTextView.imageFileReadGateForTesting = { await gate.wait() }
        defer { ACPNSTextView.imageFileReadGateForTesting = nil }
        textView.string = "send this"
        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([temp as NSURL])

        textView.paste(nil)
        textView.string = ""
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        #expect(textView.string.isEmpty)

        await gate.open()
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(textView.string.isEmpty)
        #expect(try imageAttachmentData(in: textView).isEmpty)
    }

    @Test("submit waits while image picker file read is pending")
    func submitWaitsWhileImagePickerFileReadIsPending() async throws {
        let textView = ACPNSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        var submitCount = 0
        var submittedAttachments: [ACPMessage.Attachment] = []
        let coordinator = makeCoordinator(sendOnEnter: true) { _, attachments, _, _, _ in
            submitCount += 1
            submittedAttachments = attachments
            return true
        }
        textView.coordinator = coordinator
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("alas-picker-\(UUID().uuidString).png")
        try pngBytes.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        let gate = ACPImageReadGate()
        ACPNSTextView.imageFileReadGateForTesting = { await gate.wait() }
        defer { ACPNSTextView.imageFileReadGateForTesting = nil }
        textView.string = "describe "
        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))

        textView.insertPickedImageFilesForTesting([temp])
        coordinator.submit(textView)
        #expect(submitCount == 0)

        await gate.open()
        for _ in 0..<20 where (try imageAttachmentData(in: textView)).isEmpty {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        coordinator.submit(textView)

        #expect(submitCount == 1)
        #expect(submittedAttachments.count == 1)
    }

    @Test("image picker file read is discarded after draft is cleared")
    func imagePickerFileReadIsDiscardedAfterDraftIsCleared() async throws {
        let textView = ACPNSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        let coordinator = makeCoordinator(sendOnEnter: true) { _, _, _, _, _ in true }
        textView.coordinator = coordinator
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("alas-picker-\(UUID().uuidString).png")
        try pngBytes.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        let gate = ACPImageReadGate()
        ACPNSTextView.imageFileReadGateForTesting = { await gate.wait() }
        defer { ACPNSTextView.imageFileReadGateForTesting = nil }
        textView.string = "describe "

        textView.insertPickedImageFilesForTesting([temp])
        textView.string = ""
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        await gate.open()
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(textView.string.isEmpty)
        #expect(try imageAttachmentData(in: textView).isEmpty)
    }

    @Test("async image paste advances after replacing selected text")
    func asyncImagePasteAdvancesAfterReplacingSelectedText() async throws {
        let textView = ACPNSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        var first = pngBytes
        first.append(0x01)
        var second = pngBytes
        second.append(0x02)
        let firstURL = FileManager.default.temporaryDirectory.appendingPathComponent("alas-paste-\(UUID().uuidString)-1.png")
        let secondURL = FileManager.default.temporaryDirectory.appendingPathComponent("alas-paste-\(UUID().uuidString)-2.png")
        try first.write(to: firstURL)
        try second.write(to: secondURL)
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }
        textView.string = "replace me"
        textView.setSelectedRange(NSRange(location: 0, length: 7))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([firstURL as NSURL, secondURL as NSURL])

        textView.paste(nil)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(textView.string.hasSuffix(" me"))
        #expect(try imageAttachmentData(in: textView) == [first, second])
    }

    @Test("plain paste insertion goes through NSTextView editing hooks")
    func plainPasteInsertionUsesTextViewEditingHooks() {
        let textView = ACPNSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        let window = NSWindow(contentRect: textView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = textView
        window.makeFirstResponder(textView)
        textView.allowsUndo = true
        textView.string = "before after"
        textView.setSelectedRange(NSRange(location: 7, length: 0))
        let delegate = EditingHookDelegate()
        textView.delegate = delegate

        let inserted = textView.insertPlainText("RICH")

        #expect(inserted)
        #expect(delegate.changes == [
            EditingHookDelegate.Change(
                range: NSRange(location: 7, length: 0),
                replacement: "RICH"
            )
        ])
        textView.undoManager?.undo()
        #expect(textView.string == "before after")
    }

    private final class EditingHookDelegate: NSObject, NSTextViewDelegate {
        struct Change: Equatable {
            let range: NSRange
            let replacement: String?
        }

        var changes: [Change] = []

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            changes.append(Change(range: affectedCharRange, replacement: replacementString))
            return true
        }
    }

    private actor ACPImageErrorRecorder {
        private var errors: [ACPImageStaging.StagingError] = []

        func append(_ error: ACPImageStaging.StagingError) {
            errors.append(error)
        }

        func snapshot() -> [ACPImageStaging.StagingError] { errors }
    }

    private actor ACPImageReadGate {
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            await withCheckedContinuation { continuation in
                if open {
                    continuation.resume()
                } else {
                    waiters.append(continuation)
                }
            }
        }

        func open() async {
            open = true
            let continuations = waiters
            waiters.removeAll()
            for continuation in continuations {
                continuation.resume()
            }
        }
    }

    private var pngBytes: Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
    }

    private func imageAttachmentData(in textView: ACPNSTextView) throws -> [Data] {
        var data: [Data] = []
        textView.textStorage?.enumerateAttribute(.imageAttachmentURI, in: NSRange(location: 0, length: textView.attributedString().length)) { value, _, _ in
            guard let raw = value as? String,
                  let url = URL(string: raw),
                  let bytes = try? Data(contentsOf: url) else { return }
            data.append(bytes)
        }
        return data
    }

    // MARK: - Keyboard intent resolution (doCommandBy)

    private func assertComposerBaseStyle(
        in attributed: NSAttributedString,
        range: NSRange,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        attributed.enumerateAttributes(in: range) { attrs, _, _ in
            let font = attrs[.font] as? NSFont
            let color = attrs[.foregroundColor] as? NSColor
            #expect(font?.pointSize == 13, sourceLocation: sourceLocation)
            #expect(color == NSColor.labelColor, sourceLocation: sourceLocation)
        }
    }

    private func makeCoordinator(
        sendOnEnter: Bool,
        onSubmit: @escaping ACPComposerSubmitHandler
    ) -> ACPInputField.Coordinator {
        ACPInputField.Coordinator(
            worktreeRoot: URL(fileURLWithPath: "/tmp"),
            initialDraft: .empty,
            focusRequest: 0,
            sendOnEnter: sendOnEnter,
            onDraftChange: { _ in },
            onDraftClear: {},
            onSubmit: onSubmit
        )
    }

    private func makeSlashTextView() -> (ACPNSTextView, ACPInputField.Coordinator, NSWindow) {
        let textView = ACPNSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        // presentSlashPanel() needs a window to position the panel against.
        // `textView.window` is unowned, so the caller must keep the returned
        // window alive for as long as the text view is used.
        let window = NSWindow(contentRect: textView.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView?.addSubview(textView)
        let coordinator = makeCoordinator(sendOnEnter: true) { _, _, _, _, _ in true }
        coordinator.promptSuggestions = [
            ACPPromptSuggestion(command: "/init", description: "Initialize"),
            ACPPromptSuggestion(command: "/review", description: "Review"),
        ]
        coordinator.theme = Theme(
            id: "test",
            name: "Test",
            tokens: [
                "fg": "#ffffff",
                "fg-faint": "#888888",
                "accent": "#5fb7c4",
            ]
        )
        coordinator.textView = textView
        textView.coordinator = coordinator
        return (textView, coordinator, window)
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

    @Test("draft from content blocks replaces the @marker with the chip in place")
    func draftFromBlocks() {
        // Mirror the real serializer: a single text block carrying the
        // inline `@File.swift ` marker plus a matching resource link. The
        // marker must be REPLACED by the chip in place — not kept alongside
        // it — or the mention duplicates on resubmit.
        let blocks: [ACPContentBlock] = [
            .text("look at @File.swift "),
            .resourceLink(uri: "file:///tmp/File.swift", name: "File.swift"),
        ]

        #expect(ACPComposerDraft(blocks: blocks) == ACPComposerDraft(segments: [
            .text("look at "),
            .mention(displayName: "File.swift", uri: "file:///tmp/File.swift"),
        ]))
    }

    @Test("a mid-text mention keeps its inline position (text survives on both sides)")
    func midTextMentionPosition() {
        // The common case codex flagged: insert a mention, then keep typing.
        // The chip is NOT at the tail, so the marker must be replaced in
        // place — leaving the trailing text intact — rather than stripped
        // from the end (which would leave a literal `@File.swift` AND append
        // a duplicate chip).
        let blocks: [ACPContentBlock] = [
            .text("look at @File.swift right here"),
            .resourceLink(uri: "file:///tmp/File.swift", name: "File.swift"),
        ]

        #expect(ACPComposerDraft(blocks: blocks) == ACPComposerDraft(segments: [
            .text("look at "),
            .mention(displayName: "File.swift", uri: "file:///tmp/File.swift"),
            .text("right here"),
        ]))
    }

    @Test("two markers map to two chips in order, preserving surrounding text")
    func twoMarkers() {
        let blocks: [ACPContentBlock] = [
            .text("compare @A.swift with @B.swift now"),
            .resourceLink(uri: "file:///A.swift", name: "A.swift"),
            .resourceLink(uri: "file:///B.swift", name: "B.swift"),
        ]

        #expect(ACPComposerDraft(blocks: blocks) == ACPComposerDraft(segments: [
            .text("compare "),
            .mention(displayName: "A.swift", uri: "file:///A.swift"),
            .text("with "),
            .mention(displayName: "B.swift", uri: "file:///B.swift"),
            .text("now"),
        ]))
    }

    @Test("lossy-inverse limitation: a literal @name colliding with an attachment is claimed first")
    func literalCollisionIsKnownLimitation() {
        // Documents an accepted edge of inverting a LOSSY serialization
        // (codex finding): once a chip becomes `@name ` text it's
        // indistinguishable from a literal the user typed. With a literal
        // "@here" AND an attachment named "here", the forward scan claims
        // the FIRST occurrence. This is the lesser evil vs. breaking every
        // ordinary mid-text mention — the result is still exactly one chip
        // with the correct uri, no duplication.
        let blocks: [ACPContentBlock] = [
            .text("ping @here and stuff @here "),
            .resourceLink(uri: "file:///tmp/here", name: "here"),
        ]

        let restored = ACPComposerDraft(blocks: blocks)
        let mentionCount = restored.segments.filter {
            if case .mention = $0 { return true } else { return false }
        }.count
        #expect(mentionCount == 1)
        // First occurrence is claimed; the trailing literal remains text.
        #expect(restored == ACPComposerDraft(segments: [
            .text("ping "),
            .mention(displayName: "here", uri: "file:///tmp/here"),
            .text("and stuff @here "),
        ]))
    }

    @Test("plain text blocks with no links pass through unchanged")
    func draftFromPlainText() {
        #expect(ACPComposerDraft(blocks: [.text("just words")])
            == ACPComposerDraft(segments: [.text("just words")]))
    }

    @Test("the user space before a mention is preserved")
    func spaceBeforeMentionPreserved() {
        // The space the user typed before `@` lives in the preceding text
        // and ends up in the prefix; extract's synthetic space sits AFTER
        // the marker and is consumed with it. Round-trip preserves the
        // user's separator exactly.
        let original = ACPComposerDraft(segments: [
            .text("see "),
            .mention(displayName: "File.swift", uri: "file:///tmp/File.swift"),
        ])
        let attributed = ACPInputField.Coordinator.attributedString(from: original)
        let (text, attachments) = ACPInputField.Coordinator.extract(attributed)
        let restored = ACPComposerDraft(
            blocks: ACPSessionRunner.blocks(text: text, attachments: attachments))

        #expect(restored == original)                       // space intact
        if case .text(let t)? = restored.segments.first {
            #expect(t == "see ")                            // not "see"
        } else {
            Issue.record("expected a leading text segment")
        }
    }

    @Test("queued prompt with a mid-text mention round-trips with position preserved")
    func mentionRoundTrip() {
        // The exact path a queued item travels: composer draft →
        // extract (text + attachments) → ACPSessionRunner.blocks →
        // ACPComposerDraft(blocks:). The mention must keep its INLINE
        // position with text on both sides — no doubled mention, no dropped
        // one (the codex P2 findings).
        //
        // `extract` emits `@name ` with a trailing space, and the inverse
        // consumes that marker separator when replacing it with the mention
        // chip. The user's following text remains unchanged.
        let original = ACPComposerDraft(segments: [
            .text("please review "),
            .mention(displayName: "File.swift", uri: "file:///tmp/File.swift"),
            .text("now"),
        ])

        let attributed = ACPInputField.Coordinator.attributedString(from: original)
        let (text, attachments) = ACPInputField.Coordinator.extract(attributed)
        let blocks = ACPSessionRunner.blocks(text: text, attachments: attachments)
        let restored = ACPComposerDraft(blocks: blocks)

        #expect(restored == ACPComposerDraft(segments: [
            .text("please review "),
            .mention(displayName: "File.swift", uri: "file:///tmp/File.swift"),
            .text("now"),
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

    @Test("image block becomes an image segment carrying its uri and mime")
    func imageBlockBecomesImageSegment() {
        #expect(ACPComposerDraft(blocks: [
            .image(data: nil, uri: "file:///tmp/shot.png", mimeType: "image/png"),
        ]) == ACPComposerDraft(segments: [
            .image(uri: "file:///tmp/shot.png", mimeType: "image/png"),
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

@MainActor
private final class ACPTestUndoOwner: NSObject, NSTextViewDelegate {
    let manager = UndoManager()
    func undoManager(for view: NSTextView) -> UndoManager? { manager }
}
