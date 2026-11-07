import AlasCore
import CryptoKit
import Darwin
import Foundation

enum QualificationMode: String, Sendable {
    case allowOnce = "allow-once"
    case cancel
}

enum QualificationDecisionPolicy {
    enum Refusal: String { case classification, subject, input, command, cwd, locations, options }
    struct Assessment {
        let optionID: String?
        let refusal: Refusal?
        static func refuse(_ reason: Refusal) -> Self { .init(optionID: nil, refusal: reason) }
    }

    static func selectOption(in request: ACPV2InteractiveRequest, expectedCommand: String,
        directory: URL, mode: QualificationMode) -> String? {
        guard mode == .allowOnce else { return nil }
        return assess(in: request, expectedCommand: expectedCommand, directory: directory).optionID
    }

    static func assess(in request: ACPV2InteractiveRequest, expectedCommand: String, directory: URL) -> Assessment {
        guard case .permission(let permission) = request.classification else { return .refuse(.classification) }
        guard let subject = permission.subject, case .toolCall = subject.kind,
              case .object(let fields) = subject.rawValue,
              case .object(let tool)? = fields["toolCall"], tool["kind"] == .string("execute") else { return .refuse(.subject) }
        guard case .object(let input)? = tool["rawInput"],
              Set(input.keys).isSubset(of: ["command", "cwd", "description"]) else { return .refuse(.input) }
        guard case .string(let command)? = input["command"],
              command.utf8.elementsEqual(expectedCommand.utf8) else { return .refuse(.command) }
        if let cwd = input["cwd"] {
            guard case .string(let path) = cwd, path.hasPrefix("/") else { return .refuse(.cwd) }
            let requested = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
            let expected = directory.resolvingSymlinksInPath().standardizedFileURL.path
            guard requested.utf8.elementsEqual(expected.utf8) else { return .refuse(.cwd) }
        }
        if let locations = tool["locations"] {
            guard case .array(let values) = locations else { return .refuse(.locations) }
            let target = directory.appendingPathComponent("permission-probe.txt").standardizedFileURL
            for value in values {
                guard case .object(let location) = value, case .string(let path)? = location["path"],
                      path.hasPrefix("/"), URL(fileURLWithPath: path).standardizedFileURL == target else { return .refuse(.locations) }
            }
        }
        let offered = permission.options.filter { $0.kind == "allow_once" }
        guard offered.count == 1 else { return .refuse(.options) }
        return .init(optionID: offered[0].optionID, refusal: nil)
    }
}

enum QualificationIdentity {
    enum Failure: Error { case invalidPackage, unsupportedFile, escapingLink, changedFile }

    /// Version 1: length-prefixed relative paths, file kinds, executable bits and bytes.
    /// The entire installed tree is included, including bundled dependencies and binaries.
    static func packageDigest(at directory: URL) throws -> String {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        var enumerationError: (any Error)?
        guard let enumeration = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
            errorHandler: { _, error in enumerationError = error
            return false }) else { throw Failure.invalidPackage }
        let files = enumeration.compactMap { $0 as? URL }.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        if let enumerationError { throw enumerationError }
        var hash = SHA256()
        func append(_ data: Data) {
            var count = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &count) { hash.update(bufferPointer: $0) }
            hash.update(data: data)
        }
        append(Data("alas-package-tree-v1".utf8))
        for file in files {
            let relative = String(file.path.dropFirst(root.path.count + 1))
            var metadata = stat()
            guard lstat(file.path, &metadata) == 0 else { throw Failure.invalidPackage }
            append(Data(relative.utf8))
            switch metadata.st_mode & mode_t(S_IFMT) {
            case mode_t(S_IFDIR):
                append(Data("directory".utf8))
            case mode_t(S_IFLNK):
                let target = file.resolvingSymlinksInPath().standardizedFileURL
                guard target.path.hasPrefix(root.path + "/"), FileManager.default.fileExists(atPath: target.path) else { throw Failure.escapingLink }
                append(Data("link".utf8))
                append(Data(try FileManager.default.destinationOfSymbolicLink(atPath: file.path).utf8))
            case mode_t(S_IFREG):
                append(Data("file".utf8))
                append(Data(String(metadata.st_mode & 0o111).utf8))
                guard metadata.st_size >= 0 else { throw Failure.invalidPackage }
                let size = UInt64(metadata.st_size)
                var framedSize = size.bigEndian
                withUnsafeBytes(of: &framedSize) { hash.update(bufferPointer: $0) }
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                var read: UInt64 = 0
                while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    read += UInt64(chunk.count)
                    hash.update(data: chunk)
                }
                var after = stat()
                guard lstat(file.path, &after) == 0, read == size, after.st_size == metadata.st_size,
                      after.st_mode == metadata.st_mode, after.st_ino == metadata.st_ino, after.st_dev == metadata.st_dev,
                      after.st_mtimespec.tv_sec == metadata.st_mtimespec.tv_sec,
                      after.st_mtimespec.tv_nsec == metadata.st_mtimespec.tv_nsec else { throw Failure.changedFile }
            default: throw Failure.unsupportedFile
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func fileDigest(_ file: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: file, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
    }
}
