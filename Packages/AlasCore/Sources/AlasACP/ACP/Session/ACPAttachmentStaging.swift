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

    /// The staged PDFs a draft already holds, in the terms of the per-message limits.
    public struct StagedPDFUsage: Equatable, Sendable {
        public let count: Int
        public let bytes: Int

        public init(count: Int, bytes: Int) {
            self.count = count
            self.bytes = bytes
        }
    }

    public static let maxPDFBytesPerMessage = 20 * 1024 * 1024
    public static let maxPDFsPerMessage = 5
    static let pdfMIMEType = "application/pdf"

    private static let pdfMagic = Data("%PDF-".utf8)
    private static let maxFileNameBytes = 200

    // MARK: - Staging

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
        let url = stagedFile(named: sanitizedPDFFileName(fileName), in: folder)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Always written, not skipped when present: a file whose contents
            // changed would otherwise stay refused however often it's attached again.
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            throw StagingError.writeFailed
        }
    }

    /// `name` in `folder`, spelled as an existing file is: on a case-insensitive
    /// volume, a second spelling of a name is that same file.
    private static func stagedFile(named name: String, in folder: URL) -> URL {
        let url = folder.appendingPathComponent(name)
        guard (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeRegular,
              let real = realPath(url.path) else { return url }
        return folder.appendingPathComponent(URL(fileURLWithPath: real).lastPathComponent)
    }

    static func hasPDFMagic(_ data: Data) -> Bool {
        data.starts(with: pdfMagic)
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

    // MARK: - Attach time

    /// What `uris`, the mentions on a draft, already spend of the limits. Each
    /// mention counts, like at send, so the same file twice counts twice. A missing
    /// file is left out: it holds no bytes, and send refuses it whatever else fits.
    public static func stagedPDFUsage(ofURIs uris: [String], attachmentsDirectory: URL) -> StagedPDFUsage {
        var count = 0
        var bytes = 0
        for uri in uris {
            guard case .file(let url) = stagedReference(uri: uri, attachmentsDirectory: attachmentsDirectory),
                  let size = regularFileSize(atPath: url.path) else { continue }
            count += 1
            bytes += size
        }
        return StagedPDFUsage(count: count, bytes: bytes)
    }

    // MARK: - Send time

    /// What `uri` is to the attachments. A path shaped like a staged PDF anywhere
    /// under an `acp-attachments` directory is another worktree's, unless it sits
    /// directly in `attachmentsDirectory`. An id is an absolute path, so worktrees
    /// aren't siblings, and the shape alone also catches a path from another home.
    ///
    /// The path is taken as spelled, so a dot segment breaks the shape, and compared
    /// against what the kernel resolves, so a symlink in either direction doesn't
    /// count. Both stay `.notStaged`. No bytes are read.
    public static func stagedReference(uri: String, attachmentsDirectory: URL) -> StagedReference {
        guard let url = URL(string: uri), url.isFileURL else { return .notStaged }
        let path = url.path
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 3, !parts.contains(".."), !parts.contains("."),
              isStagedShape(hash: parts[parts.count - 2], name: parts[parts.count - 1]) else { return .notStaged }
        let tail = parts.suffix(2).joined(separator: "/")
        if relativePath(path, under: attachmentsDirectory) == tail {
            guard let real = realPath(path) else { return .missing }
            return isSameFile(real, resolvedPath(of: attachmentsDirectory) + "/" + tail)
                ? .file(URL(fileURLWithPath: real)) : .notStaged
        }
        // At least one component of id between the root and the file.
        guard let root = parts.dropLast(3).lastIndex(of: Substring(Paths.acpAttachmentsRoot.lastPathComponent)) else {
            return .notStaged
        }
        guard let real = realPath(path) else { return .otherWorktree }
        let rootPath = URL(fileURLWithPath: parts[...root].joined(separator: "/"))
        let relative = parts[(root + 1)...].joined(separator: "/")
        return isSameFile(real, resolvedPath(of: rootPath) + "/" + relative) ? .otherWorktree : .notStaged
    }

    /// Case-insensitively: a staged file spelled in another case is that file on
    /// APFS, while a symlink out of the directory differs by more than case.
    private static func isSameFile(_ real: String, _ expected: String) -> Bool {
        real.lowercased() == expected.lowercased()
    }

    /// Everything that can refuse `blocks` without loading a file: where each
    /// staged mention points, the adapter, each file's magic bytes, and the size
    /// limits. Cheap enough to run before anything irreversible, such as cancelling
    /// a turn or recording a row. The size is a lower bound, since it can't see
    /// base64's escaped slashes or images, so it never refuses a prompt that fits.
    public static func preflightRefusal(
        of blocks: [ACPContentBlock],
        agentInfo: ACPImplementationInfo?,
        promptCapabilities: ACPInitializeResult.ACPPromptCapabilities,
        attachmentsDirectory: URL
    ) -> ACPPromptRefusal? {
        do throws(ACPPromptRefusal) {
            let files = try stagedPDFs(
                in: blocks, agentInfo: agentInfo,
                promptCapabilities: promptCapabilities, attachmentsDirectory: attachmentsDirectory)
            for file in files where !startsWithPDFMagic(file.url) {
                throw .pdfInvalid(name: file.name)
            }
            try ACPPromptSizeGuard.check(blocks)
            var empty = blocks
            for file in files {
                empty[file.index] = .blobResource(uri: file.uri, mimeType: pdfMIMEType, blob: "")
            }
            let base64Bytes = files.reduce(0) { $0 + ($1.size + 2) / 3 * 4 }
            let encodedBytes = ACPPromptSizeGuard.encodedSize(of: empty) + base64Bytes
            guard encodedBytes <= ACPPromptSizeGuard.maxEncodedBytes else {
                throw .promptTooLarge(encodedBytes: encodedBytes)
            }
            return nil
        } catch {
            return error
        }
    }

    /// The blobs for every staged PDF in `blocks`, by block index. The magic bytes
    /// are checked here because a staged file can change between attach and send.
    public static func embeddedPDFBlocks(
        in blocks: [ACPContentBlock],
        agentInfo: ACPImplementationInfo?,
        promptCapabilities: ACPInitializeResult.ACPPromptCapabilities,
        attachmentsDirectory: URL
    ) throws(ACPPromptRefusal) -> [Int: ACPContentBlock] {
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
    ) throws(ACPPromptRefusal) -> [(index: Int, uri: String, name: String, url: URL, size: Int)] {
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
        var files: [(index: Int, uri: String, name: String, url: URL, size: Int)] = []
        for item in staged {
            guard case .file(let url) = item.reference, let size = regularFileSize(atPath: url.path) else {
                throw .pdfMissing(name: item.name)
            }
            totalBytes += size
            guard totalBytes <= maxPDFBytesPerMessage else { throw .pdfsTooLarge(name: item.name) }
            files.append((item.index, item.uri, item.name, url, size))
        }
        return files
    }

    // MARK: - Files

    private static func startsWithPDFMagic(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: pdfMagic.count)).flatMap { $0 }.map(hasPDFMagic) ?? false
    }

    /// `attributesOfItem`, not `URL.resourceValues`, which caches.
    private static func regularFileSize(atPath path: String) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber
        else { return nil }
        return size.intValue
    }

    static func realPath(_ path: String) -> String? {
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

    /// Removes what staging put directly in `directory`: images named
    /// `<sha256>.<ext>` and PDF folders named `<sha256>` that hold only files.
    /// Anything else stays, such as the folder of a worktree whose path is
    /// under this one's (which holds PDF folders, even under a hash-shaped
    /// name), and the directory itself goes only once it is empty. A missing
    /// directory is nothing to remove.
    public static func removeStaged(in directory: URL) throws {
        let fileManager = FileManager.default
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: directory.path)
        } catch CocoaError.fileReadNoSuchFile {
            return
        }
        for name in names {
            let hash = name.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)[0]
            guard isSHA256Hex(hash) else { continue }
            let entry = directory.appendingPathComponent(name)
            if try entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                let children = try fileManager.contentsOfDirectory(
                    at: entry, includingPropertiesForKeys: [.isDirectoryKey])
                guard try children.allSatisfy({ try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory != true })
                else { continue }
            }
            try fileManager.removeItem(at: entry)
        }
        if try fileManager.contentsOfDirectory(atPath: directory.path).isEmpty {
            try fileManager.removeItem(at: directory)
        }
    }

    private static func isSHA256Hex(_ text: Substring) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    private static func isStagedShape(hash: Substring, name: Substring) -> Bool {
        name.hasSuffix(".pdf") && isSHA256Hex(hash)
    }
}
