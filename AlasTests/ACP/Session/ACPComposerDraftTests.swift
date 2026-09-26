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

    @Test("plain text spells mentions as @filename and drops image chips")
    func plainTextSpellsChips() {
        let draft = ACPComposerDraft(segments: [
            .text("/review "),
            .mention(displayName: "File.swift", uri: "file:///tmp/File.swift"),
            .image(uri: "file:///tmp/shot.png", mimeType: "image/png"),
            .text(" tail"),
        ])
        #expect(draft.plainText == "/review @File.swift tail")
        #expect(!draft.plainText.contains("\u{FFFC}"))
    }

    @Test("plain text inserts a separator when a mention directly abuts non-whitespace text")
    func plainTextSeparatesAbuttingMentionAndText() {
        let draft = ACPComposerDraft(segments: [
            .mention(displayName: "File.swift", uri: "file:///tmp/File.swift"),
            .text("right here"),
        ])
        #expect(draft.plainText == "@File.swift right here")
    }

    @Test("plain text does not double a separator already present after a mention")
    func plainTextDoesNotDoubleExistingSeparator() {
        let draft = ACPComposerDraft(segments: [
            .mention(displayName: "File.swift", uri: "file:///tmp/File.swift"),
            .text(" already spaced"),
        ])
        #expect(draft.plainText == "@File.swift already spaced")
    }

    @Test("plain text separates a mention that abuts text only through an intervening image")
    func plainTextSeparatesMentionAcrossImage() {
        let draft = ACPComposerDraft(segments: [
            .mention(displayName: "File.swift", uri: "file:///tmp/File.swift"),
            .image(uri: "file:///tmp/shot.png", mimeType: "image/png"),
            .text("right here"),
        ])
        #expect(draft.plainText == "@File.swift right here")
    }

    @Test("plain text needs no trailing separator when a mention is the last segment")
    func plainTextTrailingMentionNeedsNoSeparator() {
        let draft = ACPComposerDraft(segments: [.text("see "), .mention(displayName: "File.swift", uri: "file:///tmp/File.swift")])
        #expect(draft.plainText == "see @File.swift")
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

    @Test("persisted prompt matching ignores checkpoint references")
    func persistedPromptMatchingIgnoresCheckpointReferences() {
        let draft = ACPComposerDraft(segments: [.text("Ship it")])

        #expect(draft.matchesPersistedUserPrompt(
            text: "Ship it",
            attachments: [.checkpointReference(id: UUID())]))
    }

    @Test("imageTextOffsets is empty when there are no image segments")
    func imageTextOffsetsEmptyWithoutImages() {
        let draft = ACPComposerDraft(segments: [.text("no images here")])
        #expect(draft.imageTextOffsets() == [])
    }

    @Test("imageTextOffsets reports the character offset before a mid-sentence image")
    func imageTextOffsetsMidSentence() {
        let draft = ACPComposerDraft(segments: [
            .text("before "),
            .image(uri: "file:///tmp/shot.png", mimeType: "image/png"),
            .text(" after")
        ])
        #expect(draft.imageTextOffsets() == [7])
    }

    @Test("imageTextOffsets reports zero for a leading image")
    func imageTextOffsetsLeadingImage() {
        let draft = ACPComposerDraft(segments: [
            .image(uri: "file:///tmp/shot.png", mimeType: "image/png"),
            .text("after")
        ])
        #expect(draft.imageTextOffsets() == [0])
    }

    @Test("imageTextOffsets accounts for a mention's rendered '@name ' text")
    func imageTextOffsetsAfterMention() {
        let draft = ACPComposerDraft(segments: [
            .mention(displayName: "File.swift", uri: "file:///tmp/File.swift"),
            .image(uri: "file:///tmp/shot.png", mimeType: "image/png")
        ])
        // "@File.swift " is 12 characters.
        #expect(draft.imageTextOffsets() == [12])
    }

    @Test("imageTextOffsets reports one offset per image, in order")
    func imageTextOffsetsMultipleImages() {
        let draft = ACPComposerDraft(segments: [
            .text("a "),
            .image(uri: "file:///tmp/1.png", mimeType: "image/png"),
            .text("b "),
            .image(uri: "file:///tmp/2.png", mimeType: "image/png")
        ])
        #expect(draft.imageTextOffsets() == [2, 4])
    }
}
