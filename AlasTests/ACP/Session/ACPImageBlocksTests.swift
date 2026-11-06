import Foundation
import Testing
@testable import Alas

@Suite("ACP image blocks")
@MainActor
struct ACPImageBlocksTests {
    private static let noAttachments = URL(fileURLWithPath: "/nonexistent/acp-attachments/wt")

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
    func hydrateFallsBack() async throws {
        let deferred: [ACPContentBlock] = [
            .text("x"),
            .image(data: nil, uri: "file:///tmp/shot.png", mimeType: "image/png")
        ]
        let wire = try await ACPSessionRunner.hydrate(
            deferred,
            promptCapabilities: .init(image: false),
            worktreePath: "/tmp",
            agentInfo: nil,
            attachmentsDirectory: Self.noAttachments
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

    @Test("attachments(of:) leaves textOffset nil without a draft")
    func attachmentsWithoutDraftHaveNoTextOffset() {
        let atts = ACPSessionRunner.attachments(of: [
            .image(data: nil, uri: "file:///tmp/shot.png", mimeType: "image/png")
        ])
        #expect(atts.first?.textOffset == nil)
    }

    @Test("attachments(of:) assigns textOffset from the draft's image order")
    func attachmentsWithDraftAssignTextOffset() {
        let draft = ACPComposerDraft(segments: [
            .text("before "),
            .image(uri: "file:///tmp/shot.png", mimeType: "image/png"),
            .text(" after")
        ])
        let atts = ACPSessionRunner.attachments(
            of: [
                .text("before  after"),
                .image(data: nil, uri: "file:///tmp/shot.png", mimeType: "image/png")
            ],
            draft: draft
        )
        #expect(atts.first { $0.uri == "file:///tmp/shot.png" }?.textOffset == 7)
    }

    @Test("attachments(of:) assigns offsets to multiple images in order, skipping a resourceLink between them")
    func attachmentsWithDraftMultipleImages() {
        let draft = ACPComposerDraft(segments: [
            .text("a "),
            .image(uri: "file:///tmp/1.png", mimeType: "image/png"),
            .text("b "),
            .image(uri: "file:///tmp/2.png", mimeType: "image/png")
        ])
        let atts = ACPSessionRunner.attachments(
            of: [
                .text("a  b "),
                .image(data: nil, uri: "file:///tmp/1.png", mimeType: "image/png"),
                .resourceLink(uri: "file:///tmp/File.swift", name: "File.swift"),
                .image(data: nil, uri: "file:///tmp/2.png", mimeType: "image/png")
            ],
            draft: draft
        )
        #expect(atts.first { $0.uri == "file:///tmp/1.png" }?.textOffset == 2)
        #expect(atts.first { $0.uri == "file:///tmp/2.png" }?.textOffset == 4)
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

        let wire = try await ACPSessionRunner.hydrate(
            [.resourceLink(uri: file.absoluteString, name: "File.swift")],
            promptCapabilities: .init(embeddedContext: true),
            worktreePath: root.path,
            agentInfo: nil,
            attachmentsDirectory: Self.noAttachments
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

        let unsupported = try await ACPSessionRunner.hydrate(
            [.resourceLink(uri: outside.absoluteString, name: "outside.txt")],
            promptCapabilities: .init(embeddedContext: false),
            worktreePath: root.path,
            agentInfo: nil,
            attachmentsDirectory: Self.noAttachments
        )
        #expect(unsupported == [.resourceLink(uri: outside.absoluteString, name: "outside.txt")])

        let outsideWorktree = try await ACPSessionRunner.hydrate(
            [.resourceLink(uri: outside.absoluteString, name: "outside.txt")],
            promptCapabilities: .init(embeddedContext: true),
            worktreePath: root.path,
            agentInfo: nil,
            attachmentsDirectory: Self.noAttachments
        )
        #expect(outsideWorktree == [.resourceLink(uri: outside.absoluteString, name: "outside.txt")])
    }

    @Test("hydrate never expands symbol links into file contents")
    func hydrateLeavesSymbolLinks() async throws {
        let link = ACPContentBlock.resourceLink(
            uri: ACPSymbolReference.uri(for: .init(path: "a.swift", name: "a", kind: .function,
                                                   container: nil, lineRange: 0...0, includeCode: true)),
            name: "a()"
        )
        let wire = try await ACPSessionRunner.hydrate([link], promptCapabilities: .init(embeddedContext: true), worktreePath: "/tmp", agentInfo: nil, attachmentsDirectory: Self.noAttachments)
        #expect(wire == [link])
    }

    // MARK: - Staged PDFs

    private static let pdfBytes = Data("%PDF-1.7\nhello".utf8)
    private static let claude = ACPImplementationInfo(name: "@alas-ide/claude-agent-acp", version: "0.101.0-alas.1")
    private static let eligible = ACPInitializeResult.ACPPromptCapabilities(embeddedContext: true)

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("alas-hydrate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    private func hydrate(
        _ blocks: [ACPContentBlock], in directory: URL, worktreePath: String = "/nonexistent-worktree",
        agentInfo: ACPImplementationInfo? = ACPImageBlocksTests.claude,
        capabilities: ACPInitializeResult.ACPPromptCapabilities = ACPImageBlocksTests.eligible
    ) async throws -> [ACPContentBlock] {
        try await ACPSessionRunner.hydrate(
            blocks, promptCapabilities: capabilities, worktreePath: worktreePath,
            agentInfo: agentInfo, attachmentsDirectory: directory)
    }

    @Test("a staged PDF becomes a blob on an eligible adapter, keeping its URI and place")
    func hydrateEmbedsStagedPDF() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let staged = try ACPAttachmentStaging.stagePDF(data: Self.pdfBytes, fileName: "a.pdf", inDirectory: dir)
        let uri = staged.absoluteString
        let wire = try await hydrate([.text("x"), .resourceLink(uri: uri, name: "a.pdf"), .text("y")], in: dir)
        #expect(wire == [
            .text("x"),
            .blobResource(uri: uri, mimeType: "application/pdf", blob: Self.pdfBytes.base64EncodedString()),
            .text("y"),
        ])
    }

    @Test("a staged PDF on a non-eligible adapter fails naming the file", arguments: [
        (ACPImplementationInfo?.some(.init(name: "@alas-ide/codex-acp", version: "2.5.0-alas.6")), true),
        (ACPImplementationInfo?.none, true),
        (ACPImplementationInfo?.some(.init(name: "@alas-ide/claude-agent-acp", version: "0.100.0-alas.1")), true),
        (ACPImplementationInfo?.some(.init(name: "@alas-ide/claude-agent-acp", version: "0.101.0-alas.1")), false),
    ])
    func hydrateRefusesOnNonEligibleAdapter(info: ACPImplementationInfo?, embeddedContext: Bool) async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let staged = try ACPAttachmentStaging.stagePDF(data: Self.pdfBytes, fileName: "a.pdf", inDirectory: dir)
        await #expect(throws: ACPPromptRefusal.pdfNotSupportedByAgent(name: "a.pdf")) {
            _ = try await hydrate(
                [.resourceLink(uri: staged.absoluteString, name: "a.pdf")], in: dir,
                agentInfo: info, capabilities: .init(embeddedContext: embeddedContext))
        }
    }

    @Test("a staged file that is gone or no longer a PDF fails naming the file", arguments: [true, false])
    func hydrateRechecksTheStagedFile(deleted: Bool) async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let staged = try ACPAttachmentStaging.stagePDF(data: Self.pdfBytes, fileName: "a.pdf", inDirectory: dir)
        if deleted {
            try FileManager.default.removeItem(at: staged)
        } else {
            try Data("changed".utf8).write(to: staged)
        }
        await #expect(throws: deleted ? ACPPromptRefusal.pdfMissing(name: "a.pdf") : .pdfInvalid(name: "a.pdf")) {
            _ = try await hydrate([.resourceLink(uri: staged.absoluteString, name: "a.pdf")], in: dir)
        }
    }

    @Test("a staged file grown past the cap is refused without reading it")
    func hydrateRechecksSizeFromMetadata() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let staged = try ACPAttachmentStaging.stagePDF(data: Self.pdfBytes, fileName: "a.pdf", inDirectory: dir)
        let handle = try FileHandle(forWritingTo: staged)
        try handle.truncate(atOffset: UInt64(ACPAttachmentStaging.maxPDFBytesPerMessage + 1))
        try handle.close()
        // Unreadable, so reading it would report a different refusal.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: staged.path)
        await #expect(throws: ACPPromptRefusal.pdfsTooLarge(name: "a.pdf")) {
            _ = try await hydrate([.resourceLink(uri: staged.absoluteString, name: "a.pdf")], in: dir)
        }
    }

    @Test("the PDF limits apply to the whole message")
    func hydrateEnforcesPerMessageLimits() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        func stage(_ marker: String, size: Int = 32) throws -> ACPContentBlock {
            var bytes = Self.pdfBytes + Data(marker.utf8)
            bytes.append(Data(count: size - bytes.count))
            let url = try ACPAttachmentStaging.stagePDF(data: bytes, fileName: "\(marker).pdf", inDirectory: dir)
            return .resourceLink(uri: url.absoluteString, name: "\(marker).pdf")
        }
        let five = try (0..<ACPAttachmentStaging.maxPDFsPerMessage).map { try stage("n\($0)") }
        #expect(try await hydrate(five, in: dir).count == 5)
        let six = try five + [stage("n5")]
        await #expect(throws: ACPPromptRefusal.tooManyPDFs(count: 6)) { _ = try await hydrate(six, in: dir) }

        let half = ACPAttachmentStaging.maxPDFBytesPerMessage / 2
        let exact = try [stage("a", size: half), stage("b", size: half)]
        #expect(try await hydrate(exact, in: dir).count == 2)
        let over = try exact + [stage("c")]
        await #expect(throws: ACPPromptRefusal.pdfsTooLarge(name: "c.pdf")) { _ = try await hydrate(over, in: dir) }
    }

    @Test("a mention outside this worktree's attachments stays a link and is never read")
    func hydrateLeavesForeignStagedPathsAlone() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let own = root.appendingPathComponent("wt-a", isDirectory: true)
        let foreign = try ACPAttachmentStaging.stagePDF(
            data: Self.pdfBytes, fileName: "a.pdf", inDirectory: root.appendingPathComponent("wt-b", isDirectory: true))
        let hash = foreign.deletingLastPathComponent().lastPathComponent
        for uri in [foreign.absoluteString, "file://\(own.path)/\(hash)/../../wt-b/\(hash)/a.pdf"] {
            let link = ACPContentBlock.resourceLink(uri: uri, name: "a.pdf")
            #expect(try await hydrate([link], in: own) == [link])
            // Staged-shaped but foreign: no adapter makes it a refusal either.
            #expect(try await hydrate([link], in: own, agentInfo: nil) == [link])
        }
    }

    @Test("a worktree PDF mention is never upgraded to a blob")
    func hydrateNeverUpgradesWorktreeMention() async throws {
        let worktree = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: worktree) }
        let pdf = worktree.appendingPathComponent("doc.pdf")
        // Not UTF-8, so the text-resource path leaves it a link as well.
        try (Self.pdfBytes + Data([0xFF, 0xFE])).write(to: pdf)
        let link = ACPContentBlock.resourceLink(uri: pdf.absoluteString, name: "doc.pdf")
        let wire = try await hydrate([link], in: Self.noAttachments, worktreePath: worktree.path)
        #expect(wire == [link])
    }
}
