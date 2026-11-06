import Foundation
import Testing
import AlasCore

struct ACPAttachmentClassifierTests {
    typealias Classifier = ACPAttachmentClassifier
    typealias Usage = ACPAttachmentStaging.StagedPDFUsage

    private static let mebibyte = 1024 * 1024
    private static let noPDFsYet = Usage(count: 0, bytes: 0)

    private func file(_ name: String, _ kind: Classifier.Kind, bytes: Int? = 100) -> Classifier.File {
        Classifier.File(url: URL(fileURLWithPath: "/drop/\(name)"), kind: kind, bytes: bytes)
    }

    private func acceptedNames(_ plan: Classifier.Plan) -> [String] {
        plan.accepted.map(\.url.lastPathComponent)
    }

    private func refusedNames(_ plan: Classifier.Plan) -> [String] {
        plan.refused.map(\.name)
    }

    // MARK: - Classification

    @Test("a mixed drop attaches what it can in the order given and names the rest")
    func mixedDrop() {
        let plan = Classifier.classify(
            [file("first.png", .image), file("notes.txt", .unsupported), file("report.pdf", .pdf), file("last.jpg", .image)],
            pdfs: .init(eligible: true, usage: Self.noPDFsYet))

        #expect(plan.accepted.map(\.kind) == [.image, .pdf, .image])
        #expect(acceptedNames(plan) == ["first.png", "report.pdf", "last.jpg"])
        #expect(plan.refused == [.init(name: "notes.txt", reason: .unsupported)])
        #expect(plan.handlesFiles)
    }

    @Test("only a session known not to take PDFs refuses one at attach", arguments: [
        (eligible: Bool?.none, attaches: true),
        (eligible: Bool?.some(true), attaches: true),
        (eligible: Bool?.some(false), attaches: false),
    ])
    func eligibility(eligible: Bool?, attaches: Bool) {
        let plan = Classifier.classify([file("report.pdf", .pdf)], pdfs: .init(eligible: eligible, usage: Self.noPDFsYet))

        #expect(acceptedNames(plan) == (attaches ? ["report.pdf"] : []))
        #expect(plan.refused == (attaches ? [] : [.init(name: "report.pdf", reason: .agentCannotReadPDFs)]))
        #expect(plan.handlesFiles)
    }

    @Test("the file limit counts the PDFs already on the draft and the ones earlier in the drop")
    func fileLimit() {
        let plan = Classifier.classify(
            [file("a.pdf", .pdf), file("b.pdf", .pdf), file("c.pdf", .pdf)],
            pdfs: .init(eligible: true, usage: Usage(count: ACPAttachmentStaging.maxPDFsPerMessage - 2, bytes: 0)))

        #expect(acceptedNames(plan) == ["a.pdf", "b.pdf"])
        #expect(plan.refused == [.init(name: "c.pdf", reason: .tooManyPDFs)])
    }

    @Test("the size limit is a running total, and a smaller file later in the drop can still fit")
    func sizeLimit() {
        let limit = ACPAttachmentStaging.maxPDFBytesPerMessage
        let plan = Classifier.classify(
            [
                file("fills.pdf", .pdf, bytes: limit - Self.mebibyte - 1),
                file("too-big.pdf", .pdf, bytes: Self.mebibyte + 2),
                file("exactly-fits.pdf", .pdf, bytes: Self.mebibyte),
                file("one-byte-over.pdf", .pdf, bytes: 2),
            ],
            pdfs: .init(eligible: nil, usage: Usage(count: 0, bytes: 1)))

        #expect(acceptedNames(plan) == ["fills.pdf", "exactly-fits.pdf"])
        #expect(refusedNames(plan) == ["too-big.pdf", "one-byte-over.pdf"])
        #expect(plan.refused.allSatisfy { $0.reason == .pdfsTooLarge })
    }

    @Test("a file that claims to be a PDF is reported instead of falling through as text", arguments: [
        (kind: Classifier.Kind.notPDF, reason: Classifier.Reason.notPDF),
        (kind: Classifier.Kind.unreadable, reason: Classifier.Reason.unreadable),
    ])
    func brokenPDF(kind: Classifier.Kind, reason: Classifier.Reason) {
        let plan = Classifier.classify([file("report.pdf", kind)], pdfs: .init(eligible: false, usage: Self.noPDFsYet))

        #expect(plan.refused == [.init(name: "report.pdf", reason: reason)])
        #expect(plan.handlesFiles)
    }

    @Test("files with nothing to attach stay with the text path", arguments: [true, false])
    func nothingToAttach(offersPDFs: Bool) {
        let plan = Classifier.classify(
            [file("notes.txt", .unsupported), file("folder", .unsupported, bytes: nil)],
            pdfs: offersPDFs ? .init(eligible: nil, usage: Self.noPDFsYet) : nil)

        #expect(!plan.handlesFiles)
        #expect(plan.accepted.isEmpty)
    }

    @Test("the image size limit is unchanged, and still applies to a large file of any other type")
    func imageLimit() {
        let limit = ACPImageStaging.maxBytes
        let plan = Classifier.classify(
            [
                file("fits.png", .image, bytes: limit),
                file("big.png", .image, bytes: limit + 1),
                file("big.mov", .unsupported, bytes: limit + 1),
            ],
            pdfs: nil)

        #expect(acceptedNames(plan) == ["fits.png"])
        #expect(plan.refused == [
            .init(name: "big.png", reason: .image(.tooLarge)),
            .init(name: "big.mov", reason: .image(.tooLarge)),
        ])
        #expect(plan.handlesFiles)
    }

    // MARK: - Notice

    @Test("the notice names every refused file, grouping those refused for the same reason")
    func notice() throws {
        let notice = try #require(Classifier.notice(for: [
            .init(name: "a.pdf", reason: .agentCannotReadPDFs),
            .init(name: "notes.txt", reason: .unsupported),
            .init(name: "b.pdf", reason: .agentCannotReadPDFs),
        ]))

        #expect(notice == "Couldn't attach a.pdf, b.pdf: this agent can't read attached PDFs. Couldn't attach notes.txt: only images and PDFs can be attached.")
        #expect(Classifier.notice(for: []) == nil)
    }

    // MARK: - Probing

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("alas-pdf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    @Test("a file's kind comes from its bytes, with the name only marking a broken PDF", arguments: [
        (name: "real.pdf", contents: "%PDF-1.7\nhello", kind: Classifier.Kind.pdf),
        (name: "no-extension", contents: "%PDF-1.7\nhello", kind: .pdf),
        (name: "fake.PDF", contents: "not a pdf", kind: .notPDF),
        (name: "notes.txt", contents: "hello", kind: .unsupported),
        (name: "picture.pdf", contents: "\u{47}\u{49}\u{46}\u{38}\u{39}\u{61}", kind: .image),
    ])
    func probesContents(name: String, contents: String, kind: Classifier.Kind) throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent(name)
            try Data(contents.utf8).write(to: url)

            let probed = Classifier.probe(url)

            #expect(probed.kind == kind)
            #expect(probed.bytes == contents.utf8.count)
        }
    }

    @Test("a symlink is measured and sniffed as the file it points at")
    func probesSymlinkTarget() throws {
        try withDirectory { directory in
            let target = directory.appendingPathComponent("target.bin")
            try Data("%PDF-1.7\nhello".utf8).write(to: target)
            let link = directory.appendingPathComponent("link.pdf")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

            let probed = Classifier.probe(link)

            #expect(probed.kind == .pdf)
            #expect(probed.bytes == 14)
        }
    }

    @Test("a file that can't be read is only broken when named like an attachment, and a folder never is", arguments: [
        (name: "gone.pdf", kind: Classifier.Kind.unreadable),
        (name: "gone.png", kind: .unreadable),
        (name: "gone.txt", kind: .unsupported),
    ])
    func probesWithoutAFile(name: String, kind: Classifier.Kind) throws {
        try withDirectory { directory in
            #expect(Classifier.probe(directory.appendingPathComponent(name)).kind == kind)
            let folder = directory.appendingPathComponent("folder.pdf", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            #expect(Classifier.probe(folder).kind == .unsupported)
        }
    }

    // MARK: - What the draft already holds

    @Test("usage counts each chip of a staged PDF and sums their bytes")
    func usage() throws {
        try withDirectory { directory in
            let first = try ACPAttachmentStaging.stagePDF(data: Data("%PDF-1.7\nhello".utf8), fileName: "a.pdf", inDirectory: directory)
            let second = try ACPAttachmentStaging.stagePDF(data: Data("%PDF-1.7\nlonger".utf8), fileName: "b.pdf", inDirectory: directory)

            let usage = ACPAttachmentStaging.stagedPDFUsage(
                ofURIs: [first.absoluteString, first.absoluteString, second.absoluteString],
                attachmentsDirectory: directory)

            #expect(usage == Usage(count: 3, bytes: 14 + 14 + 15))
        }
    }
}
