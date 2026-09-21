import Foundation
import Testing
@testable import Alas

@Suite("ACPUserMessageImageMarkers")
struct ACPUserMessageImageMarkersTests {
    @Test("returns text unchanged when there are no image attachments")
    func noImages() {
        let text = ACPUserMessageImageMarkers.displayText(
            text: "hello",
            attachments: [.init(uri: "file:///tmp/File.swift", name: "File.swift")])
        #expect(text == "hello")
    }

    @Test("inserts a single unnumbered marker at the image's offset")
    func singleImage() {
        let text = ACPUserMessageImageMarkers.displayText(
            text: "shows  - should be",
            attachments: [.init(uri: "file:///tmp/shot.png", name: "shot.png", mimeType: "image/png", textOffset: 6)])
        #expect(text == "shows `🖼 image` - should be")
    }

    @Test("inserts numbered markers for multiple images at their own offsets")
    func multipleImages() {
        let text = ACPUserMessageImageMarkers.displayText(
            text: "a b",
            attachments: [
                .init(uri: "file:///tmp/1.png", name: "1.png", mimeType: "image/png", textOffset: 1),
                .init(uri: "file:///tmp/2.png", name: "2.png", mimeType: "image/png", textOffset: 3)
            ])
        #expect(text == "a`🖼 1` b`🖼 2`")
    }

    @Test("skips an image attachment with no captured offset")
    func nilOffsetSkipped() {
        let text = ACPUserMessageImageMarkers.displayText(
            text: "hello",
            attachments: [.init(uri: "file:///tmp/shot.png", name: "shot.png", mimeType: "image/png")])
        #expect(text == "hello")
    }

    @Test("keeps stable numbering when a middle image has no offset")
    func middleImageWithoutOffsetKeepsNumbering() {
        let text = ACPUserMessageImageMarkers.displayText(
            text: "ac",
            attachments: [
                .init(uri: "file:///tmp/1.png", name: "1.png", mimeType: "image/png", textOffset: 0),
                .init(uri: "file:///tmp/2.png", name: "2.png", mimeType: "image/png"),
                .init(uri: "file:///tmp/3.png", name: "3.png", mimeType: "image/png", textOffset: 1)
            ])
        #expect(text == "`🖼 1`a`🖼 3`c")
    }

    @Test("clamps an out-of-range offset to the end of the text")
    func clampsOutOfRangeOffset() {
        let text = ACPUserMessageImageMarkers.displayText(
            text: "hi",
            attachments: [.init(uri: "file:///tmp/shot.png", name: "shot.png", mimeType: "image/png", textOffset: 999)])
        #expect(text == "hi`🖼 image`")
    }

    @Test("separates two markers sharing an offset so their backticks don't merge")
    func sharedOffsetKeepsAttachmentOrder() {
        let text = ACPUserMessageImageMarkers.displayText(
            text: "x",
            attachments: [
                .init(uri: "file:///tmp/1.png", name: "1.png", mimeType: "image/png", textOffset: 0),
                .init(uri: "file:///tmp/2.png", name: "2.png", mimeType: "image/png", textOffset: 0)
            ])
        // Without a separating space, "`🖼 1``🖼 2`" is a single run of two
        // backticks between the labels, which Markdown parses as ONE merged
        // code span instead of two.
        #expect(text == "`🖼 1` `🖼 2`x")
    }

    @Test("separates a marker from adjacent pre-existing inline code so the spans don't merge")
    func adjacentInlineCodeDoesNotMerge() {
        // An image chip placed immediately before literal `foo` text: with
        // no separator, "`🖼 image``foo`" is backtick, text, a RUN OF TWO
        // backticks, text, backtick — Markdown looks for the next
        // single-backtick run to close the first span and finds the
        // trailing one after "foo", merging both into one corrupted span.
        let before = ACPUserMessageImageMarkers.displayText(
            text: "`foo`",
            attachments: [.init(uri: "file:///tmp/shot.png", name: "shot.png", mimeType: "image/png", textOffset: 0)])
        #expect(before == "`🖼 image` `foo`")

        let after = ACPUserMessageImageMarkers.displayText(
            text: "`foo`",
            attachments: [.init(uri: "file:///tmp/shot.png", name: "shot.png", mimeType: "image/png", textOffset: 5)])
        #expect(after == "`foo` `🖼 image`")
    }

    @Test("ignores non-image attachments entirely")
    func ignoresNonImageAttachments() {
        let text = ACPUserMessageImageMarkers.displayText(
            text: "look at ",
            attachments: [
                .init(uri: "file:///tmp/File.swift", name: "File.swift"),
                .init(uri: "file:///tmp/shot.png", name: "shot.png", mimeType: "image/png", textOffset: 8)
            ])
        #expect(text == "look at `🖼 image`")
    }
}
