import AppKit
import Foundation
import Testing
@testable import Alas

@Suite("ACPMarkdownLiveStyler image chip preservation")
@MainActor
struct ACPMarkdownLiveStylerImageChipTests {
    /// Regression: the live styler resets attributes on every edit. Image
    /// chips are tagged with `.imageAttachmentURI` (not `.attachmentURI`),
    /// so an earlier version bulldozed their `.attachment` cell on the
    /// debounced restyle — the chip flashed in then vanished.
    @Test("restyle preserves an image chip's attachment and uri attribute")
    func preservesImageChip() {
        let storage = NSTextStorage(string: "look ")
        let url = URL(string: "file:///tmp/shot.png")!
        let attachment = ACPImageChipAttachment(fileURL: url, mimeType: "image/png")
        let chip = NSMutableAttributedString(attachment: attachment)
        chip.addAttributes([
            .imageAttachmentURI: url.absoluteString,
            .imageAttachmentMime: "image/png",
        ], range: NSRange(location: 0, length: chip.length))
        storage.append(chip)
        storage.append(NSAttributedString(string: " **bold** after"))

        ACPMarkdownLiveStyler.restyle(storage, in: NSRange(location: 0, length: storage.length))

        // The chip occupies the single attachment character right after "look ".
        let chipIndex = 5
        #expect(storage.attribute(.imageAttachmentURI, at: chipIndex, effectiveRange: nil) as? String == url.absoluteString)
        #expect(storage.attribute(.attachment, at: chipIndex, effectiveRange: nil) is ACPImageChipAttachment)
    }
}
