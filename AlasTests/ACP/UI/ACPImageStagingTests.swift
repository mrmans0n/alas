import CryptoKit
import Foundation
import Testing
@testable import Alas

@Suite("ACPImageStaging")
struct ACPImageStagingTests {
    // A minimal valid 1x1 PNG.
    private var pngBytes: Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
    }

    @Test("sniffs png mime and writes a content-addressed file")
    func stagesPNG() throws {
        let staged = try ACPImageStaging.stage(data: pngBytes, into: "wt-test")
        #expect(staged.mimeType == "image/png")
        #expect(staged.url.pathExtension == "png")
        #expect(FileManager.default.fileExists(atPath: staged.url.path))
        try? FileManager.default.removeItem(at: staged.url)
    }

    @Test("identical bytes dedupe to the same path")
    func dedupes() throws {
        let a = try ACPImageStaging.stage(data: pngBytes, into: "wt-test")
        let b = try ACPImageStaging.stage(data: pngBytes, into: "wt-test")
        #expect(a.url == b.url)
        try? FileManager.default.removeItem(at: a.url)
    }

    @Test("rejects non-image bytes")
    func rejectsNonImage() {
        #expect(throws: ACPImageStaging.StagingError.self) {
            _ = try ACPImageStaging.stage(data: Data("not an image".utf8), into: "wt-test")
        }
    }

    @Test("rejects oversized images")
    func rejectsOversize() {
        var big = pngBytes
        big.append(Data(count: ACPImageStaging.maxBytes + 1))
        #expect(throws: ACPImageStaging.StagingError.self) {
            _ = try ACPImageStaging.stage(data: big, into: "wt-test")
        }
    }

    // MARK: - PDFs

    private static let pdfBytes = Data("%PDF-1.7\nhello".utf8)

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("alas-pdf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("a PDF is stored under its content hash with its sanitized name, once")
    func stagesPDFContentAddressed() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try ACPAttachmentStaging.stagePDF(data: Self.pdfBytes, fileName: "../Report.PDF", inDirectory: dir)
        let second = try ACPAttachmentStaging.stagePDF(data: Self.pdfBytes, fileName: "../Report.PDF", inDirectory: dir)
        let hash = SHA256.hash(data: Self.pdfBytes).map { String(format: "%02x", $0) }.joined()
        #expect(first == second)
        #expect(first == dir.appendingPathComponent(hash).appendingPathComponent("Report.pdf"))
        #expect(try Data(contentsOf: first) == Self.pdfBytes)
    }

    @Test("refuses bytes that do not start with the PDF magic", arguments: ["", "%PDF", "not a pdf", " %PDF-1.7"])
    func refusesNonPDFBytes(bytes: String) throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: ACPAttachmentStaging.StagingError.notPDF) {
            _ = try ACPAttachmentStaging.stagePDF(data: Data(bytes.utf8), fileName: "a.pdf", inDirectory: dir)
        }
    }

    @Test("refuses bytes past the size cap")
    func enforcesPDFCap() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var bytes = Self.pdfBytes
        bytes.append(Data(count: ACPAttachmentStaging.maxPDFBytesPerMessage + 1 - bytes.count))
        #expect(throws: ACPAttachmentStaging.StagingError.tooLarge) {
            _ = try ACPAttachmentStaging.stagePDF(data: bytes, fileName: "a.pdf", inDirectory: dir)
        }
    }

    @Test("the same bytes under a name differing only in case stage as the file already there")
    func stagesCaseVariantAsExistingFile() throws {
        let dir = try makeDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try ACPAttachmentStaging.stagePDF(data: Self.pdfBytes, fileName: "Report.pdf", inDirectory: dir)
        let second = try ACPAttachmentStaging.stagePDF(data: Self.pdfBytes, fileName: "REPORT.pdf", inDirectory: dir)
        #expect(second == first)
        #expect(ACPAttachmentStaging.stagedPDFUsage(ofURIs: [second.absoluteString], attachmentsDirectory: dir).count == 1)
    }

    @Test("attaching a PDF again repairs a staged file whose contents changed")
    func restagingRepairsChangedFile() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let staged = try ACPAttachmentStaging.stagePDF(data: Self.pdfBytes, fileName: "a.pdf", inDirectory: dir)
        try Data("corrupted".utf8).write(to: staged)
        _ = try ACPAttachmentStaging.stagePDF(data: Self.pdfBytes, fileName: "a.pdf", inDirectory: dir)
        #expect(try Data(contentsOf: staged) == Self.pdfBytes)
    }

    @Test("an oversized file is refused from its metadata, without reading it")
    func refusesOversizedFileBeforeReading() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("big.pdf")
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: UInt64(ACPAttachmentStaging.maxPDFBytesPerMessage + 1))
        try handle.close()
        // Unreadable, so reading it would report `.unreadable` instead.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: source.path)
        #expect(throws: ACPAttachmentStaging.StagingError.tooLarge) {
            _ = try ACPAttachmentStaging.stagePDF(fileURL: source, inDirectory: dir.appendingPathComponent("out"))
        }
    }

    @Test("a name with URL-reserved characters survives the round trip through the chip's URI")
    func stagedNameRoundTripsThroughURI() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("a #?%.pdf")
        try Self.pdfBytes.write(to: source)
        let out = dir.appendingPathComponent("out", isDirectory: true)
        let staged = try ACPAttachmentStaging.stagePDF(fileURL: source, inDirectory: out)
        guard case .file(let url) = ACPAttachmentStaging.stagedReference(uri: staged.absoluteString, attachmentsDirectory: out) else {
            Issue.record("not recognized as staged")
            return
        }
        #expect(url.lastPathComponent == "a #?%.pdf")
    }

    @Test("a dropped symlink stages the file it points at, under the link's name")
    func stagesPDFThroughSymlink() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("target.pdf")
        try Self.pdfBytes.write(to: target)
        let link = dir.appendingPathComponent("link.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let staged = try ACPAttachmentStaging.stagePDF(fileURL: link, inDirectory: dir.appendingPathComponent("out"))
        #expect(staged.lastPathComponent == "link.pdf")
        #expect(try Data(contentsOf: staged) == Self.pdfBytes)
    }

    @Test("sanitizes a file name", arguments: [
        ("report.pdf", "report.pdf"),
        ("Report.PDF", "Report.pdf"),
        ("no-extension", "no-extension.pdf"),
        ("../../etc/passwd.pdf", "passwd.pdf"),
        (#"..\..\evil.pdf"#, "evil.pdf"),
        (".hidden.pdf", "hidden.pdf"),
        ("a:b\u{0}c\nd.pdf", "a_b_c_d.pdf"),
        ("résumé final.pdf", "résumé final.pdf"),
        ("", "document.pdf"),
        ("..", "document.pdf"),
        (".pdf", "document.pdf"),
    ])
    func sanitizesPDFName(input: String, expected: String) {
        #expect(ACPAttachmentStaging.sanitizedPDFFileName(input) == expected)
    }

    @Test("caps a long file name without splitting a character")
    func capsLongPDFName() {
        let name = ACPAttachmentStaging.sanitizedPDFFileName(String(repeating: "é", count: 400) + ".pdf")
        #expect(name.hasSuffix("é.pdf"))
        #expect(name.utf8.count <= 255)
    }

    enum StagedShape: CaseIterable, Sendable {
        case own, caseVariant, missing, otherWorktree, otherWorktreeMissing, otherWorktreeLink, differentParent, nestedInOwn, parentOfOwn
        case dotDotEscape, rootDotDotMissing, encodedDotDot, encodedSlash, linkEscape, worktreeLinkIn, flatFile, notAFileURI
    }

    @Test("only this worktree's own staged path counts as staged", arguments: StagedShape.allCases)
    func classifiesStagedReference(shape: StagedShape) throws {
        let temp = try makeDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = temp.appendingPathComponent("acp-attachments", isDirectory: true)
        // Worktree ids are absolute paths, so they nest under the root.
        let own = root.appendingPathComponent("Users/n/wt-a", isDirectory: true)
        let other = root.appendingPathComponent("Users/n/wt-b", isDirectory: true)
        let staged = try ACPAttachmentStaging.stagePDF(data: Self.pdfBytes, fileName: "a.pdf", inDirectory: own)
        let hash = staged.deletingLastPathComponent().lastPathComponent
        let foreign = try ACPAttachmentStaging.stagePDF(data: Self.pdfBytes, fileName: "b.pdf", inDirectory: other)
        let fm = FileManager.default
        let uri: String
        let expected: ACPAttachmentStaging.StagedReference
        switch shape {
        case .own:
            // Resolved: the temporary directory itself sits behind a symlink.
            let real = try #require(realpath(staged.path, nil))
            defer { free(real) }
            (uri, expected) = (staged.absoluteString, .file(URL(fileURLWithPath: String(cString: real))))
        case .caseVariant:
            let real = try #require(realpath(staged.path, nil))
            defer { free(real) }
            (uri, expected) = (staged.deletingLastPathComponent().appendingPathComponent("A.pdf").absoluteString, .file(URL(fileURLWithPath: String(cString: real))))
        case .differentParent:
            let elsewhere = root.appendingPathComponent("Users/m/wt-c", isDirectory: true)
            (uri, expected) = (try ACPAttachmentStaging.stagePDF(data: Self.pdfBytes, fileName: "c.pdf", inDirectory: elsewhere).absoluteString, .otherWorktree)
        case .nestedInOwn:
            let nested = own.appendingPathComponent("nested", isDirectory: true)
            (uri, expected) = (try ACPAttachmentStaging.stagePDF(data: Self.pdfBytes, fileName: "c.pdf", inDirectory: nested).absoluteString, .otherWorktree)
        case .parentOfOwn:
            let parent = own.deletingLastPathComponent()
            (uri, expected) = (try ACPAttachmentStaging.stagePDF(data: Self.pdfBytes, fileName: "c.pdf", inDirectory: parent).absoluteString, .otherWorktree)
        case .missing:
            (uri, expected) = (staged.deletingLastPathComponent().appendingPathComponent("gone.pdf").absoluteString, .missing)
        case .otherWorktree:
            (uri, expected) = (foreign.absoluteString, .otherWorktree)
        case .otherWorktreeMissing:
            (uri, expected) = (foreign.deletingLastPathComponent().appendingPathComponent("gone.pdf").absoluteString, .otherWorktree)
        case .otherWorktreeLink:
            let link = foreign.deletingLastPathComponent().appendingPathComponent("link.pdf")
            try fm.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("elsewhere.pdf"))
            try Self.pdfBytes.write(to: root.appendingPathComponent("elsewhere.pdf"))
            (uri, expected) = (link.absoluteString, .notStaged)
        case .dotDotEscape:
            (uri, expected) = ("file://\(own.path)/\(hash)/../../wt-b/\(hash)/b.pdf", .notStaged)
        case .rootDotDotMissing:
            (uri, expected) = ("file://\(root.path)/../\(hash)/gone.pdf", .notStaged)
        case .encodedDotDot:
            (uri, expected) = ("file://\(own.path)/\(hash)/%2e%2e/%2e%2e/wt-b/\(hash)/b.pdf", .notStaged)
        case .encodedSlash:
            (uri, expected) = ("file://\(root.path)/wt-b%2F\(hash)/b.pdf", .notStaged)
        case .linkEscape:
            let link = staged.deletingLastPathComponent().appendingPathComponent("link.pdf")
            try fm.createSymbolicLink(at: link, withDestinationURL: foreign)
            (uri, expected) = (link.absoluteString, .notStaged)
        case .worktreeLinkIn:
            let link = root.appendingPathComponent("worktree-link.pdf")
            try fm.createSymbolicLink(at: link, withDestinationURL: staged)
            (uri, expected) = (link.absoluteString, .notStaged)
        case .flatFile:
            let flat = own.appendingPathComponent("\(hash).pdf")
            try Self.pdfBytes.write(to: flat)
            (uri, expected) = (flat.absoluteString, .notStaged)
        case .notAFileURI:
            (uri, expected) = ("alas-session://\(own.path)/\(hash)/a.pdf", .notStaged)
        }
        #expect(ACPAttachmentStaging.stagedReference(uri: uri, attachmentsDirectory: own) == expected)
    }
}
