import CryptoKit
import Darwin
import Foundation

public enum ACPLaunchContentIdentity {
    public enum Failure: Error { case invalidPackage, unsupportedFile, escapingLink, changedFile }

    /// Version 1: length-prefixed relative paths, file kinds, executable bits and bytes.
    /// The entire installed tree is included, including bundled dependencies and binaries.
    public static func packageDigest(at directory: URL) throws -> String {
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
            try Task.checkCancellation()
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
                    try Task.checkCancellation()
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

    public static func fileDigest(_ file: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: file, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
    }
}
