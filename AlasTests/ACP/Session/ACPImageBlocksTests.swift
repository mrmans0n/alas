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
        let wire = await ACPSessionRunner.hydrate(
            deferred,
            promptCapabilities: .init(image: false),
            worktreePath: "/tmp"
        )
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

    @Test("hydrate embeds readable worktree text resource when supported")
    func hydrateEmbedsTextResource() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-acp-resource-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("File.swift")
        try "let value = 1\n".write(to: file, atomically: true, encoding: .utf8)

        let wire = await ACPSessionRunner.hydrate(
            [.resourceLink(uri: file.absoluteString, name: "File.swift")],
            promptCapabilities: .init(embeddedContext: true),
            worktreePath: root.path
        )

        #expect(wire == [
            .resource(
                uri: file.absoluteString,
                mimeType: "text/plain",
                text: "let value = 1\n"
            )
        ])
    }

    @Test("hydrate keeps resource link when embedded context is unsupported or outside worktree")
    func hydrateResourceFallbacks() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-acp-resource-\(UUID().uuidString)", isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-acp-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "outside\n".write(to: outside, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        let unsupported = await ACPSessionRunner.hydrate(
            [.resourceLink(uri: outside.absoluteString, name: "outside.txt")],
            promptCapabilities: .init(embeddedContext: false),
            worktreePath: root.path
        )
        #expect(unsupported == [.resourceLink(uri: outside.absoluteString, name: "outside.txt")])

        let outsideWorktree = await ACPSessionRunner.hydrate(
            [.resourceLink(uri: outside.absoluteString, name: "outside.txt")],
            promptCapabilities: .init(embeddedContext: true),
            worktreePath: root.path
        )
        #expect(outsideWorktree == [.resourceLink(uri: outside.absoluteString, name: "outside.txt")])
    }
}
