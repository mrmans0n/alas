import Foundation

/// What a composer needs to take PDFs. A composer without one, such as a peer's,
/// has no PDF path at all.
public struct ACPComposerPDFAttachments: Equatable, Sendable {
    /// Where a staged PDF goes: `ACPSession.attachmentsDirectory`, since send time
    /// only embeds what is in that directory.
    public let directory: URL
    /// `nil` until the session is connected; see `ACPEmbeddedPDFSupport.attachmentEligibility`.
    public let eligible: Bool?

    public init(directory: URL, eligible: Bool?) {
        self.directory = directory
        self.eligible = eligible
    }
}

/// Decides what a dropped, pasted or picked set of files becomes, so the user
/// hears about a refused file when attaching it rather than at send.
public enum ACPAttachmentClassifier {
    public enum Kind: Equatable, Sendable {
        case image
        case pdf
        /// Named like a PDF, without the magic bytes.
        case notPDF
        /// Named like a PDF or an image, and can't be read.
        case unreadable
        case unsupported

        /// Whether this file only gets attached, or a notice, where PDFs are taken.
        /// Anywhere else it stays on the text path.
        public var needsPDFComposer: Bool {
            self == .pdf || self == .notPDF || self == .unreadable
        }
    }

    public struct File: Equatable, Sendable {
        public let url: URL
        public let kind: Kind
        /// `nil` when there is no regular file to measure.
        public let bytes: Int?

        public init(url: URL, kind: Kind, bytes: Int?) {
            self.url = url
            self.kind = kind
            self.bytes = bytes
        }
    }

    /// What the PDFs in a drop are measured against.
    public struct PDFContext: Equatable, Sendable {
        public let eligible: Bool?
        public let usage: ACPAttachmentStaging.StagedPDFUsage

        public init(eligible: Bool?, usage: ACPAttachmentStaging.StagedPDFUsage) {
            self.eligible = eligible
            self.usage = usage
        }
    }

    public enum Reason: Equatable, Sendable {
        case unsupported
        case notPDF
        case unreadable
        case agentCannotReadPDFs
        case tooManyPDFs
        case pdfsTooLarge
        case saveFailed
        case image(ACPImageStaging.StagingError)

        public init(_ error: ACPAttachmentStaging.StagingError) {
            switch error {
            case .notPDF: self = .notPDF
            case .tooLarge: self = .pdfsTooLarge
            case .unreadable: self = .unreadable
            case .writeFailed: self = .saveFailed
            }
        }

        var explanation: String {
            switch self {
            case .unsupported: "only images and PDFs can be attached"
            case .notPDF: "it isn't a valid PDF"
            case .unreadable: "the file can't be read"
            case .agentCannotReadPDFs: "this agent can't read attached PDFs"
            case .tooManyPDFs: "one message can hold \(ACPAttachmentStaging.maxPDFsPerMessage) PDFs at most"
            case .pdfsTooLarge: "the PDFs in one message can total \(ACPAttachmentStaging.maxPDFBytesPerMessage / (1024 * 1024)) MiB at most"
            case .saveFailed: "it couldn't be saved"
            case .image(.unsupportedFormat): "that image format isn't supported"
            case .image(.tooLarge): "it's over the \(ACPImageStaging.maxBytes / (1024 * 1024)) MiB limit"
            case .image(.tooManyImages): "one message can hold \(ACPImageStaging.maxImagesPerMessage) images at most"
            case .image(.writeFailed): "it couldn't be saved"
            }
        }
    }

    public struct Refusal: Equatable, Sendable {
        public let name: String
        public let reason: Reason

        public init(name: String, reason: Reason) {
            self.name = name
            self.reason = reason
        }
    }

    public struct Accepted: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case image
            case pdf
        }

        public let url: URL
        public let kind: Kind
    }

    public struct Plan: Equatable, Sendable {
        /// In the order given, which is the order the chips go in.
        public let accepted: [Accepted]
        public let refused: [Refusal]

        /// False when none of the files is something to attach, so a drop or a
        /// paste stays with the text path.
        public var handlesFiles: Bool {
            !accepted.isEmpty || refused.contains { $0.reason != .unsupported }
        }
    }

    /// `pdfs` is `nil` for a composer that doesn't take PDFs: there, one is a
    /// file like any other.
    public static func classify(_ files: [File], pdfs: PDFContext?) -> Plan {
        var accepted: [Accepted] = []
        var refused: [Refusal] = []
        var usage = pdfs?.usage ?? .init(count: 0, bytes: 0)
        for file in files {
            let name = file.url.lastPathComponent
            let reason: Reason?
            switch file.kind {
            case .image:
                reason = isOverImageLimit(file) ? .image(.tooLarge) : nil
                if reason == nil { accepted.append(.init(url: file.url, kind: .image)) }
            case .pdf where pdfs != nil:
                reason = pdfRefusal(bytes: file.bytes ?? 0, eligible: pdfs?.eligible, usage: usage)
                if reason == nil {
                    accepted.append(.init(url: file.url, kind: .pdf))
                    usage = .init(count: usage.count + 1, bytes: usage.bytes + (file.bytes ?? 0))
                }
            case .notPDF where pdfs != nil:
                reason = .notPDF
            case .unreadable where pdfs != nil:
                reason = .unreadable
            case .pdf, .notPDF, .unreadable, .unsupported:
                // The image path has always called any oversized file too large.
                reason = isOverImageLimit(file) ? .image(.tooLarge) : .unsupported
            }
            if let reason { refused.append(.init(name: name, reason: reason)) }
        }
        return Plan(accepted: accepted, refused: refused)
    }

    /// Why one more PDF of `bytes` doesn't fit next to `usage`, if it doesn't.
    public static func pdfRefusal(
        bytes: Int,
        eligible: Bool?,
        usage: ACPAttachmentStaging.StagedPDFUsage
    ) -> Reason? {
        if eligible == false { return .agentCannotReadPDFs }
        if usage.count >= ACPAttachmentStaging.maxPDFsPerMessage { return .tooManyPDFs }
        if bytes > ACPAttachmentStaging.maxPDFBytesPerMessage - usage.bytes { return .pdfsTooLarge }
        return nil
    }

    /// One notice for a whole drop: the composer shows a single line, so
    /// separate notices would overwrite each other.
    public static func notice(for refused: [Refusal]) -> String? {
        var groups: [(reason: Reason, names: [String])] = []
        for refusal in refused {
            if let index = groups.firstIndex(where: { $0.reason == refusal.reason }) {
                groups[index].names.append(refusal.name)
            } else {
                groups.append((refusal.reason, [refusal.name]))
            }
        }
        guard !groups.isEmpty else { return nil }
        return groups
            .map { "Couldn't attach \($0.names.joined(separator: ", ")): \($0.reason.explanation)." }
            .joined(separator: " ")
    }

    /// Reads metadata and a few bytes, never the whole file. A symlink is the file it points at.
    public static func probe(_ url: URL) -> File {
        let namedAttachment = attachmentExtensions.contains(url.pathExtension.lowercased())
        // `attributesOfItem`, not `URL.resourceValues`, which caches.
        guard let path = ACPAttachmentStaging.realPath(url.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        else {
            return File(url: url, kind: namedAttachment ? .unreadable : .unsupported, bytes: nil)
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            return File(url: url, kind: .unsupported, bytes: nil)
        }
        let bytes = (attributes[.size] as? NSNumber)?.intValue
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return File(url: url, kind: namedAttachment ? .unreadable : .unsupported, bytes: bytes)
        }
        defer { try? handle.close() }
        let header = (try? handle.read(upToCount: 16)) ?? Data()
        let kind: Kind
        if ACPImageStaging.sniffMIME(header) != nil {
            kind = .image
        } else if ACPAttachmentStaging.hasPDFMagic(header) {
            kind = .pdf
        } else {
            kind = url.pathExtension.lowercased() == "pdf" ? .notPDF : .unsupported
        }
        return File(url: url, kind: kind, bytes: bytes)
    }

    private static let attachmentExtensions: Set<String> = ["pdf", "png", "jpg", "jpeg", "gif", "webp"]

    private static func isOverImageLimit(_ file: File) -> Bool {
        (file.bytes ?? 0) > ACPImageStaging.maxBytes
    }
}
