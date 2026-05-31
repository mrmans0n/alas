import Foundation
import Testing
@testable import Alas

@Suite("ACP image blocks")
@MainActor
struct ACPImageBlocksTests {
    @Test("image attachment becomes a deferred image block; mention stays a link")
    func buildsDeferredImageBlock() {
        let blocks = ACPSessionRunner.blocks(
            text: "see this",
            attachments: [
                .init(uri: "file:///tmp/shot.png", name: "shot.png", mimeType: "image/png"),
                .init(uri: "file:///tmp/File.swift", name: "File.swift")
            ])
        #expect(blocks.contains(.image(data: nil, uri: "file:///tmp/shot.png", mimeType: "image/png")))
        #expect(blocks.contains(.resourceLink(uri: "file:///tmp/File.swift", name: "File.swift")))
    }

    @Test("hydrate falls back to a resource link when images are unsupported")
    func hydrateFallsBack() async {
        let deferred: [ACPContentBlock] = [
            .text("x"),
            .image(data: nil, uri: "file:///tmp/shot.png", mimeType: "image/png")
        ]
        let wire = await ACPSessionRunner.hydrate(deferred, imageInputSupported: false)
        #expect(wire.contains(.text("x")))
        #expect(wire.contains(.resourceLink(uri: "file:///tmp/shot.png", name: "shot.png")))
        #expect(!wire.contains { block in
            if case .image = block { return true }
            return false
        })
    }

    @Test("attachments(of:) surfaces image blocks as image attachments")
    func attachmentsIncludeImages() {
        let atts = ACPSessionRunner.attachments(of: [
            .image(data: nil, uri: "file:///tmp/shot.png", mimeType: "image/png")
        ])
        #expect(atts == [.init(uri: "file:///tmp/shot.png", name: "shot.png", mimeType: "image/png")])
    }

    @Test("image-only prompt omits the whitespace leading text block")
    func imageOnlyOmitsTextBlock() {
        // The composer leaves a trailing space after an image chip, so an
        // image-only prompt's extracted text is " ", not "".
        let blocks = ACPSessionRunner.blocks(
            text: " ",
            attachments: [.init(uri: "file:///tmp/shot.png", name: "shot.png", mimeType: "image/png")])
        #expect(blocks == [.image(data: nil, uri: "file:///tmp/shot.png", mimeType: "image/png")])
    }
}
