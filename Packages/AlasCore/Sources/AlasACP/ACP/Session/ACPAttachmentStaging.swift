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
            case .tooLarge: "That PDF is too large (max 20 MiB)."
            case .unreadable: "Couldn't read that PDF."
            case .writeFailed: "Couldn't save that PDF. Please try again."
            }
        }
    }

    /// What a mention's URI is to this worktree's attachments.
    public enum StagedReference: Equatable, Sendable {
        /// Any other mention, including a path that only reaches a staged file through `..` or a symlink.
        case notStaged
        /// Another worktree's staged path. Never read.
        case otherWorktree
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
        // A dropped symlink is the file it points at; `attributesOfItem` would describe the link.
        guard let source = realPath(fileURL.path), let size = regularFileSize(atPath: source) else {
            throw StagingError.unreadable
        }
        guard size <= maxPDFBytesPerMessage else { throw StagingError.tooLarge }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: source)) else { throw StagingError.unreadable }
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

    /// What `uri` is to the attachments. The path is taken as spelled, so a dot
    /// segment breaks the exact shape, and compared against what the kernel
    /// resolves, so a symlink in either direction doesn't count. No bytes are read.
    public static func stagedReference(uri: String, attachmentsDirectory: URL) -> StagedReference {
        guard let url = URL(string: uri), url.isFileURL else { return .notStaged }
        let path = url.path
        if let relative = relativePath(path, under: attachmentsDirectory) {
            let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, isStagedShape(hash: parts[0], name: parts[1]) else { return .notStaged }
            guard let real = realPath(path) else { return .missing }
            return real == resolvedPath(of: attachmentsDirectory) + "/" + relative
                ? .file(URL(fileURLWithPath: real)) : .notStaged
        }
        let root = attachmentsDirectory.deletingLastPathComponent()
        guard let relative = relativePath(path, under: root) else { return .notStaged }
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, isStagedShape(hash: parts[1], name: parts[2]) else { return .notStaged }
        guard let real = realPath(path) else { return .otherWorktree }
        return real == resolvedPath(of: root) + "/" + relative ? .otherWorktree : .notStaged
    }

    /// Everything that can refuse `blocks` without reading a file's bytes: where
    /// each staged mention points, the adapter, and the size limits. Cheap enough
    /// to run before anything irreversible, such as cancelling a turn or recording a row.
    public static func preflightRefusal(
        of blocks: [ACPContentBlock],
        agentInfo: ACPImplementationInfo?,
        promptCapabilities: ACPInitializeResult.ACPPromptCapabilities,
        attachmentsDirectory: URL
    ) -> ACPPromptRefusal? {
        do {
            _ = try stagedPDFs(
                in: blocks, agentInfo: agentInfo,
                promptCapabilities: promptCapabilities, attachmentsDirectory: attachmentsDirectory)
            try ACPPromptSizeGuard.check(blocks)
            return nil
        } catch {
            return error as? ACPPromptRefusal
        }
    }

    /// The blobs for every staged PDF in `blocks`, by block index. The magic bytes
    /// are checked here because a staged file can change between attach and send.
    public static func embeddedPDFBlocks(
        in blocks: [ACPContentBlock],
        agentInfo: ACPImplementationInfo?,
        promptCapabilities: ACPInitializeResult.ACPPromptCapabilities,
        attachmentsDirectory: URL
    ) throws -> [Int: ACPContentBlock] {
        let files = try stagedPDFs(
            in: blocks, agentInfo: agentInfo,
            promptCapabilities: promptCapabilities, attachmentsDirectory: attachmentsDirectory)
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

    private static func stagedPDFs(
        in blocks: [ACPContentBlock],
        agentInfo: ACPImplementationInfo?,
        promptCapabilities: ACPInitializeResult.ACPPromptCapabilities,
        attachmentsDirectory: URL
    ) throws -> [(index: Int, uri: String, name: String, url: URL)] {
        var staged: [(index: Int, uri: String, name: String, reference: StagedReference)] = []
        for (index, block) in blocks.enumerated() {
            guard case .resourceLink(let uri, let name) = block else { continue }
            let reference = stagedReference(uri: uri, attachmentsDirectory: attachmentsDirectory)
            let displayName = name ?? URL(string: uri)?.lastPathComponent ?? uri
            // On any adapter: its bytes belong to another worktree, and a link would lose them silently.
            if reference == .otherWorktree { throw ACPPromptRefusal.pdfFromAnotherWorktree(name: displayName) }
            if reference != .notStaged { staged.append((index, uri, displayName, reference)) }
        }
        guard !staged.isEmpty else { return [] }
        guard ACPEmbeddedPDFSupport.supports(agentInfo: agentInfo, promptCapabilities: promptCapabilities) else {
            throw ACPPromptRefusal.pdfNotSupportedByAgent(name: staged[0].name)
        }
        guard staged.count <= maxPDFsPerMessage else { throw ACPPromptRefusal.tooManyPDFs(count: staged.count) }
        var totalBytes = 0
        return try staged.map { item in
            guard case .file(let url) = item.reference, let size = regularFileSize(atPath: url.path) else {
                throw ACPPromptRefusal.pdfMissing(name: item.name)
            }
            totalBytes += size
            guard totalBytes <= maxPDFBytesPerMessage else { throw ACPPromptRefusal.pdfsTooLarge(name: item.name) }
            return (item.index, item.uri, item.name, url)
        }
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

    private static func resolvedPath(of directory: URL) -> String {
        realPath(directory.path) ?? directory.standardizedFileURL.path
    }

    /// `path` below `directory`, spelled either as given or as resolved: the
    /// directory itself may sit behind a symlink.
    private static func relativePath(_ path: String, under directory: URL) -> String? {
        [directory.standardizedFileURL.path, resolvedPath(of: directory)].lazy
            .compactMap { path.hasPrefix($0 + "/") ? String(path.dropFirst($0.count + 1)) : nil }
            .first
    }

    private static func isStagedShape(hash: Substring, name: Substring) -> Bool {
        hash.utf8.count == 64 && name.hasSuffix(".pdf")
            && hash.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}
