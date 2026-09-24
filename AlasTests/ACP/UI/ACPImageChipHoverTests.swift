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

    @Test("zero-size image falls back to the width cap")
    func zeroSizeFallsBackToWidthCap() {
        let size = ACPImageChipHoverController.fittedSize(
            for: NSSize(width: 0, height: 0),
            maxWidth: 400,
            maxHeight: 500
        )
        #expect(size.width == 400)
        #expect(size.height == 400)
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
}
