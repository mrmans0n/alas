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
}
