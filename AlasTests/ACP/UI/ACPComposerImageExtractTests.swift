import AppKit
import Foundation
import Testing
@testable import Alas

@Suite("ACP composer image extraction")
@MainActor
struct ACPComposerImageExtractTests {
    /// Build an attributed string with one image chip between two text runs,
    /// mirroring what `insertImage` produces.
    private func makeStorage() -> NSAttributedString {
        let s = NSMutableAttributedString(string: "before ")
        let url = URL(string: "file:///tmp/shot.png")!
        let attachment = ACPImageChipAttachment(fileURL: url, mimeType: "image/png")
        let chip = NSMutableAttributedString(attachment: attachment)
        chip.addAttributes([
            .imageAttachmentURI: url.absoluteString,
            .imageAttachmentMime: "image/png",
        ], range: NSRange(location: 0, length: chip.length))
        s.append(chip)
        s.append(NSAttributedString(string: " after"))
        return s
    }

    @Test("extract pulls an image attachment and omits chip from text")
    func extractsImage() {
        let (text, atts) = ACPInputField.Coordinator.extract(makeStorage())
        #expect(text == "before  after")
        #expect(atts == [.init(uri: "file:///tmp/shot.png", name: "shot.png", mimeType: "image/png")])
    }

    @Test("draft(from:) yields an image segment in place")
    func draftHasImageSegment() {
        let draft = ACPInputField.Coordinator.draft(from: makeStorage())
        #expect(draft.segments == [
            .text("before "),
            .image(uri: "file:///tmp/shot.png", mimeType: "image/png"),
            .text(" after")
        ])
    }

    @Test("image chip frame centers on surrounding text")
    func imageChipFrameCentersOnText() throws {
        let font = NSFont.systemFont(ofSize: 13)
        let url = URL(string: "file:///tmp/shot.png")!
        let attachment = ACPImageChipAttachment(fileURL: url, mimeType: "image/png")
        let storage = NSTextStorage(string: "x", attributes: [.font: font])
        let chip = NSMutableAttributedString(attachment: attachment)
        chip.addAttributes([.font: font], range: NSRange(location: 0, length: chip.length))
        storage.append(chip)
        storage.append(NSAttributedString(string: "y", attributes: [.font: font]))

        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: 200, height: 100))
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)

        let chipIndex = 1
        let baseline = NSPoint(x: 12, y: 30)
        let frame = try #require(attachment.attachmentCell).cellFrame(
            for: textContainer,
            proposedLineFragment: NSRect(x: 0, y: 0, width: 200, height: 20),
            glyphPosition: baseline,
            characterIndex: chipIndex
        )

        let textCenter = (font.ascender + font.descender) / 2
        #expect(abs(frame.midY - textCenter) < 0.001)
        #expect(frame.minY < -5)
        #expect(frame.minX == 0)
    }
}
