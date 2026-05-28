import AppKit
import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACP composer draft bridge")
struct ACPComposerDraftBridgeTests {
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
