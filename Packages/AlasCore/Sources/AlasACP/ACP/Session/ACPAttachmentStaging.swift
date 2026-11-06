import CryptoKit
import Foundation
import AlasModel

/// Stores attached PDFs under Application Support so drafts, the queue, and the
/// transcript can all reference a durable `file://` path, and turns the ones a
/// prompt mentions into embedded blobs at send time.
///
/// A staged PDF is an ordinary mention until then, so nothing persisted changes shape.
public enum ACPAttachmentStaging: Sendable {
    public enum StagingError: Error, Equatable, Sendable {
        case notPDF
        case tooLarge
        case unreadable
        case writeFailed

        public var userMessage: String {
            switch self {
            case .notPDF: "That file isn't a PDF."
            case .tooLarge: "That PDF is too large (max 20 MB)."
            case .unreadable: "Couldn't read that PDF."
            case .writeFailed: "Couldn't save that PDF. Please try again."
            }
        }
    }

    /// What a mention's URI is to this worktree's attachments.
    public enum StagedReference: Equatable, Sendable {
        /// Any other mention, including another worktree's staged file.
        case notStaged
        /// This worktree's staged path, with no file behind it.
        case missing
        case file(URL)
    }

    public static let maxPDFBytesPerMessage = 20 * 1024 * 1024
    public static let maxPDFsPerMessage = 5
    public static let pdfMIMEType = "application/pdf"

    private static let pdfMagic = Data("%PDF-".utf8)
    private static let maxFileNameBytes = 200

    // MARK: - Staging

    public static func stagePDF(fileURL: URL, into worktreeId: String) throws -> URL {
        try stagePDF(fileURL: fileURL, inDirectory: Paths.acpAttachmentsDir(forWorktreeId: worktreeId))
    }

    public static func stagePDF(data: Data, fileName: String, into worktreeId: String) throws -> URL {
        try stagePDF(data: data, fileName: fileName, inDirectory: Paths.acpAttachmentsDir(forWorktreeId: worktreeId))
    }

    /// Checks the size from metadata first, so an oversized file isn't loaded just to be refused.
    public static func stagePDF(fileURL: URL, inDirectory directory: URL) throws -> URL {
        guard let size = regularFileSize(atPath: fileURL.path) else { throw StagingError.unreadable }
        guard size <= maxPDFBytesPerMessage else { throw StagingError.tooLarge }
        guard let data = try? Data(contentsOf: fileURL) else { throw StagingError.unreadable }
        return try stagePDF(data: data, fileName: fileURL.lastPathComponent, inDirectory: directory)
    }

    public static func stagePDF(data: Data, fileName: String, inDirectory directory: URL) throws -> URL {
        guard data.count <= maxPDFBytesPerMessage else { throw StagingError.tooLarge }
        guard data.starts(with: pdfMagic) else { throw StagingError.notPDF }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let folder = directory.appendingPathComponent(hash, isDirectory: true)
        // The real name stays in the URI: Claude derives its link text from it.
        let url = folder.appendingPathComponent(sanitizedPDFFileName(fileName))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                try data.write(to: url, options: .atomic)
            }
            return url
        } catch {
            throw StagingError.writeFailed
        }
    }

    public static func sanitizedPDFFileName(_ name: String) -> String {
        let last = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        var cleaned = String(String.UnicodeScalarView(last.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) || scalar == ":" ? "_" : scalar
        }))
        if cleaned.lowercased().hasSuffix(".pdf") { cleaned.removeLast(4) }
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        // Whole characters, so a cut can't leave invalid UTF-8 in the path.
        var base = ""
        for character in cleaned where base.utf8.count + character.utf8.count <= maxFileNameBytes {
            base.append(character)
        }
        return (base.isEmpty ? "document" : base) + ".pdf"
    }

    // MARK: - Send time

    /// Whether `uri` is exactly this worktree's `<sha256>/<name>.pdf`. Compared
    /// against what the kernel resolves, so neither `..` nor a symlink, in either
    /// direction, can make another file count as staged. No bytes are read.
    public static func stagedReference(uri: String, attachmentsDirectory: URL) -> StagedReference {
        guard let url = URL(string: uri), url.isFileURL else { return .notStaged }
        let directory = attachmentsDirectory.standardizedFileURL.path
        let realDirectory = realPath(attachmentsDirectory.path) ?? directory
        let lexical = url.standardizedFileURL.path
        guard let relative = [directory, realDirectory].lazy
            .compactMap({ lexical.hasPrefix($0 + "/") ? String(lexical.dropFirst($0.count + 1)) : nil })
            .first
        else { return .notStaged }
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2, isSHA256Hex(components[0]), components[1].hasSuffix(".pdf") else {
            return .notStaged
        }
        guard let real = realPath(url.path) else { return .missing }
        let expected = realDirectory + "/" + relative
        return real == expected ? .file(URL(fileURLWithPath: real)) : .notStaged
    }

    /// The blobs for every staged PDF in `blocks`, by block index. Everything is
    /// checked from metadata before any file is read, and the magic bytes are
    /// checked again because a staged file can change between attach and send.
    public static func embeddedPDFBlocks(
        in blocks: [ACPContentBlock],
        agentInfo: ACPImplementationInfo?,
        promptCapabilities: ACPInitializeResult.ACPPromptCapabilities,
        attachmentsDirectory: URL
    ) throws -> [Int: ACPContentBlock] {
        var staged: [(index: Int, uri: String, name: String, reference: StagedReference)] = []
        for (index, block) in blocks.enumerated() {
            guard case .resourceLink(let uri, let name) = block else { continue }
            let reference = stagedReference(uri: uri, attachmentsDirectory: attachmentsDirectory)
            if reference != .notStaged {
                staged.append((index, uri, name ?? URL(string: uri)?.lastPathComponent ?? uri, reference))
            }
        }
        guard !staged.isEmpty else { return [:] }
        guard ACPEmbeddedPDFSupport.supports(agentInfo: agentInfo, promptCapabilities: promptCapabilities) else {
            throw ACPPromptRefusal.pdfNotSupportedByAgent(name: staged[0].name)
        }
        guard staged.count <= maxPDFsPerMessage else { throw ACPPromptRefusal.tooManyPDFs(count: staged.count) }

        var files: [(index: Int, uri: String, name: String, url: URL)] = []
        var totalBytes = 0
        for item in staged {
            guard case .file(let url) = item.reference,
                  let size = regularFileSize(atPath: url.path)
            else { throw ACPPromptRefusal.pdfMissing(name: item.name) }
            totalBytes += size
            guard totalBytes <= maxPDFBytesPerMessage else { throw ACPPromptRefusal.pdfsTooLarge(name: item.name) }
            files.append((item.index, item.uri, item.name, url))
        }

        var embedded: [Int: ACPContentBlock] = [:]
        var readBytes = 0
        for file in files {
            guard let data = try? Data(contentsOf: file.url) else { throw ACPPromptRefusal.pdfMissing(name: file.name) }
            // It may have grown since the metadata was read.
            readBytes += data.count
            guard readBytes <= maxPDFBytesPerMessage else { throw ACPPromptRefusal.pdfsTooLarge(name: file.name) }
            guard data.starts(with: pdfMagic) else { throw ACPPromptRefusal.pdfInvalid(name: file.name) }
            embedded[file.index] = .blobResource(uri: file.uri, mimeType: pdfMIMEType, blob: data.base64EncodedString())
        }
        return embedded
    }

    // MARK: - Files

    /// `attributesOfItem`, not `URL.resourceValues`, which caches.
    private static func regularFileSize(atPath path: String) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber
        else { return nil }
        return size.intValue
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func isSHA256Hex(_ text: Substring) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}
