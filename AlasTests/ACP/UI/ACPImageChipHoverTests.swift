import AppKit
import Testing
@testable import Alas

@MainActor
@Suite("ACP composer image chip hover popover")
struct ACPImageChipHoverTests {
    /// Writes a tiny 4×4 red PNG to a temp file and returns its URL; the
    /// caller removes it. Used as the chip's staged image in hit-test tests.
    private func makeStubPNGFile() throws -> URL {
        let stubImage = NSImage(size: NSSize(width: 4, height: 4))
        stubImage.lockFocus()
        NSColor.red.drawSwatch(in: NSRect(x: 0, y: 0, width: 4, height: 4))
        stubImage.unlockFocus()
        let tiff = try #require(stubImage.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("alas-chip-hover-test-\(UUID().uuidString).png")
        try png.write(to: fileURL)
        return fileURL
    }

    // MARK: - Sizing

    @Test("wide image fits the composer width cap and keeps its aspect ratio")
    func wideImageFitsWidthCap() {
        let size = ACPImageChipHoverController.fittedSize(
            for: NSSize(width: 2000, height: 500),
            maxWidth: 400,
            maxHeight: 500
        )
        #expect(size.width <= 400 + 0.01)
        #expect(abs(size.width / size.height - 4) < 0.01)
    }

    @Test("tall image fits the height cap and keeps its aspect ratio")
    func tallImageFitsHeightCap() {
        let size = ACPImageChipHoverController.fittedSize(
            for: NSSize(width: 500, height: 2000),
            maxWidth: 800,
            maxHeight: 400
        )
        #expect(size.height <= 400 + 0.01)
        #expect(abs(size.width / size.height - 0.25) < 0.01)
    }

    @Test("small image keeps its native size and is never upscaled")
    func smallImageStaysNative() {
        let size = ACPImageChipHoverController.fittedSize(
            for: NSSize(width: 120, height: 80),
            maxWidth: 400,
            maxHeight: 500
        )
        #expect(size.width == 120)
        #expect(size.height == 80)
    }

    @Test("square image respects the smaller of the two caps")
    func squareImageUsesSmallerCap() {
        let size = ACPImageChipHoverController.fittedSize(
            for: NSSize(width: 3000, height: 3000),
            maxWidth: 300,
            maxHeight: 600
        )
        #expect(abs(size.width - 300) < 0.01)
        #expect(abs(size.height - 300) < 0.01)
    }

    @Test("zero-size image falls back to a square bounded by both caps")
    func zeroSizeFallsBackToWidthCap() {
        let size = ACPImageChipHoverController.fittedSize(
            for: NSSize(width: 0, height: 0),
            maxWidth: 400,
            maxHeight: 500
        )
        #expect(size.width == 400)
        #expect(size.height == 400)
    }

    @Test("zero-size image respects the smaller height cap")
    func zeroSizeRespectsSmallerHeightCap() {
        let size = ACPImageChipHoverController.fittedSize(
            for: NSSize(width: 0, height: 0),
            maxWidth: 720,
            maxHeight: 450
        )
        #expect(size.width == 450)
        #expect(size.height == 450)
        #expect(size.height <= 450 + 0.01)
    }

    @Test("composer width cap falls back to the layout default without a window")
    func composerWidthCapFallsBackToDefault() throws {
        // A detached text view (no window) has no visible layout, so the
        // cap falls back to the layout's default content width rather than
        // flooring at some minimum.
        let textView = ACPNSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
        let cap = try #require(ACPNSTextView.imageChipPreviewCap(in: textView))
        #expect(cap.width == ACPChatLayout.defaultContentMaxWidth)
        #expect(cap.height > 0)
    }

    // MARK: - Chip hit-testing

    private func makeTextViewWithImageChip(fileURL: URL) throws -> (ACPNSTextView, NSRange) {
        let textView = ACPNSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        let attachment = ACPImageChipAttachment(fileURL: fileURL, mimeType: "image/png")
        let chip = NSMutableAttributedString(attachment: attachment)
        chip.addAttributes(
            [.imageAttachmentURI: fileURL.absoluteString, .imageAttachmentMime: "image/png"],
            range: NSRange(location: 0, length: chip.length)
        )
        let full = NSMutableAttributedString(string: "before ")
        full.append(chip)
        full.append(NSAttributedString(string: " after"))
        textView.textStorage?.setAttributedString(full)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let chipRange = (full.string as NSString).range(of: "\u{FFFC}")
        try #require(chipRange.location != NSNotFound && chipRange.length == 1)
        return (textView, chipRange)
    }

    @Test("point over the chip resolves its character range and URI")
    func pointOverChipResolvesRangeAndURI() throws {
        let fileURL = try makeStubPNGFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (textView, chipRange) = try makeTextViewWithImageChip(fileURL: fileURL)
        let glyphRect = try #require(textView.imageChipAnchorRect(for: chipRange))
        let point = NSPoint(x: glyphRect.midX, y: glyphRect.midY)

        let resolved = try #require(textView.imageChipRange(at: point))

        #expect(resolved.range == chipRange)
        #expect(resolved.fileURL == fileURL)
    }

    @Test("point over plain text does not resolve to a chip")
    func pointOverPlainTextDoesNotResolve() throws {
        let fileURL = try makeStubPNGFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (textView, chipRange) = try makeTextViewWithImageChip(fileURL: fileURL)
        let glyphRect = try #require(textView.imageChipAnchorRect(for: chipRange))
        // A point on the "before" text, left of the chip.
        let textPoint = NSPoint(x: glyphRect.minX - 30, y: glyphRect.midY)

        #expect(textView.imageChipRange(at: textPoint) == nil)
    }

    @Test("point over blank space beside an end-of-line chip does not resolve")
    func pointBesideEndOfLineChipDoesNotResolve() throws {
        let fileURL = try makeStubPNGFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        // Chip is the final glyph on its line — blank space to its right is
        // the exact case where TextKit's nearest-character lookup lies.
        let textView = ACPNSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        let attachment = ACPImageChipAttachment(fileURL: fileURL, mimeType: "image/png")
        let chip = NSMutableAttributedString(attachment: attachment)
        chip.addAttributes(
            [.imageAttachmentURI: fileURL.absoluteString, .imageAttachmentMime: "image/png"],
            range: NSRange(location: 0, length: chip.length)
        )
        let full = NSMutableAttributedString(string: "before ")
        full.append(chip)
        textView.textStorage?.setAttributedString(full)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let chipRange = (full.string as NSString).range(of: "\u{FFFC}")
        try #require(chipRange.location != NSNotFound)
        let glyphRect = try #require(textView.imageChipAnchorRect(for: chipRange))
        // Blank space to the right of the chip, inside the text view.
        let blankPoint = NSPoint(x: glyphRect.maxX + 30, y: glyphRect.midY)

        #expect(textView.imageChipRange(at: blankPoint) == nil)
    }

    @Test("anchor rect is a positive-size rect inside the text view")
    func anchorRectIsPositive() throws {
        let fileURL = try makeStubPNGFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (textView, chipRange) = try makeTextViewWithImageChip(fileURL: fileURL)

        let anchorRect = try #require(textView.imageChipAnchorRect(for: chipRange))
        #expect(anchorRect.width > 0)
        #expect(anchorRect.height > 0)
        #expect(textView.bounds.contains(anchorRect))
    }

    // MARK: - Dismissal on direct storage replacement

    @Test("restore and clearVisibleDraft close the hover preview")
    func draftReplacementsDismissHover() throws {
        let fileURL = try makeStubPNGFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (textView, _) = try makeTextViewWithImageChip(fileURL: fileURL)
        let chipRange = (textView.string as NSString).range(of: "\u{FFFC}")
        try #require(chipRange.location != NSNotFound)
        // `restore` resolves the coordinator through the text view.
        let coordinator = ACPInputField.Coordinator(
            worktreeRoot: URL(fileURLWithPath: NSTemporaryDirectory()),
            initialDraft: ACPComposerDraft.empty,
            focusRequest: 0,
            sendOnEnter: true,
            onDraftChange: { _ in },
            onDraftClear: {},
            onSubmit: { _, _, _, _, _ in true }
        )
        coordinator.textView = textView
        textView.coordinator = coordinator

        // Simulate a displayed preview without instantiating NSPopover/NSImage
        // machinery: an injected spy records dismissal state transitions.
        let spy = HoverControllerSpy()
        textView.imageChipHoverSpy = spy
        // Schedule the pending 250ms show exactly as a real hover would.
        textView.scheduleImageChipHoverForTesting(range: chipRange, fileURL: fileURL)

        textView.restoreDraftForTesting(
            ACPComposerDraft(segments: [.text("replaced")])
        )
        #expect(spy.didHide)
        #expect(textView.pendingImageChipHoverCountForTesting == 0)
    }

    /// Records `hide()` calls so tests can assert dismissal without
    /// constructing real popovers. Delegates to super so cancellation of
    /// the pending show work item is exercised too.
    @MainActor
    private final class HoverControllerSpy: ACPImageChipHoverController {
        private(set) var didHide = false
        override func hide() {
            didHide = true
            super.hide()
        }
    }
}
