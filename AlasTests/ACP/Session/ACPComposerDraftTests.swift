import Foundation
import Testing
@testable import Alas

@Suite("ACPComposerDraft")
struct ACPComposerDraftTests {
    @Test("codable round trip preserves ordered text and mention segments")
    func codableRoundTrip() throws {
        let draft = ACPComposerDraft(segments: [
            .text("Please inspect "),
            .mention(displayName: "File.swift", uri: "file:///tmp/File.swift"),
            .text("\nThen explain the bug.")
        ])

        let data = try JSONEncoder().encode(draft)
        let decoded = try JSONDecoder().decode(ACPComposerDraft.self, from: data)

        #expect(decoded == draft)
    }

    @Test("empty only when it has no meaningful storage segments")
    func emptyState() {
        #expect(ACPComposerDraft.empty.isEmpty)
        #expect(ACPComposerDraft(segments: [.text("")]).isEmpty)
        #expect(!ACPComposerDraft(segments: [.text(" ")]).isEmpty)
        #expect(!ACPComposerDraft(segments: [.mention(displayName: "a.swift", uri: "file:///a.swift")]).isEmpty)
    }

    @Test("codable round trip preserves an image segment")
    func codableImageRoundTrip() throws {
        let draft = ACPComposerDraft(segments: [
            .text("Look at "),
            .image(uri: "file:///tmp/shot.png", mimeType: "image/png"),
            .text(" please.")
        ])
        let data = try JSONEncoder().encode(draft)
        let decoded = try JSONDecoder().decode(ACPComposerDraft.self, from: data)
        #expect(decoded == draft)
    }

    @Test("an image-only draft has content and is not empty")
    func imageOnlyDraftHasContent() {
        let draft = ACPComposerDraft(segments: [.image(uri: "file:///tmp/a.png", mimeType: "image/png")])
        #expect(!draft.isEmpty)
        #expect(draft.hasContent)
    }

    @Test("persisted prompt matching normalizes image chips")
    func persistedPromptMatchingNormalizesImageChips() {
        let draft = ACPComposerDraft(segments: [
            .text("Look at "),
            .image(uri: "file:///tmp/shot.png", mimeType: "image/png"),
            .text(" ")
        ])

        #expect(draft.matchesPersistedUserPrompt(
            text: "Look at  ",
            attachments: [.init(uri: "file:///tmp/shot.png", name: "shot.png", mimeType: "image/png")]))
    }
}
