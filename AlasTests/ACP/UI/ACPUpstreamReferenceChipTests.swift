import AppKit
import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACP upstream reference chip")
struct ACPUpstreamReferenceChipTests {
    private func referenceChipCount(_ storage: NSAttributedString) -> Int {
        var count = 0
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if value is ACPUpstreamReferenceChipAttachment { count += 1 }
        }
        return count
    }

    @Test("chipify replaces references and the draft bridge spells them back as text")
    func chipifyRoundTrip() async {
        let store = await UpstreamReferenceFixtures.store()
        let text = "fix #12, see `#13` and (#14)"
        let storage = NSMutableAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 13)])

        #expect(ACPUpstreamReferenceChip.chipify(storage, host: .github, store: store) == 2)
        #expect(referenceChipCount(storage) == 2)
        #expect(ACPInputField.Coordinator.draft(from: storage) == ACPComposerDraft(segments: [.text(text)]))
        #expect(ACPInputField.Coordinator.extract(storage).0 == text)
        #expect(ACPUpstreamReferenceChip.plainText(of: storage) == text)
        // Existing chips are U+FFFC, never tokens, so a second pass is a no-op.
        #expect(ACPUpstreamReferenceChip.chipify(storage, host: .github, store: store) == 0)
    }

    @Test("markdown live restyling leaves the chip's attachment in place")
    func survivesRestyle() async {
        let store = await UpstreamReferenceFixtures.store()
        let storage = NSTextStorage(string: "**bold** #12 tail", attributes: [.font: NSFont.systemFont(ofSize: 13)])
        ACPUpstreamReferenceChip.chipify(storage, host: .github, store: store)

        ACPMarkdownLiveStyler.restyle(storage)

        #expect(referenceChipCount(storage) == 1)
    }

    @Test("plain text flattening is nil without reference chips")
    func plainTextNilWithoutChips() {
        #expect(ACPUpstreamReferenceChip.plainText(of: NSAttributedString(string: "#12")) == nil)
    }
}
