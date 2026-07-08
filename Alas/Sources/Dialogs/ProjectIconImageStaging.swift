import CryptoKit
import Foundation

enum ProjectIconImageStaging {
    struct Staged: Equatable {
        let imagePath: String
        let url: URL
    }

    enum StagingError: Error, Equatable {
        case unsupportedFormat
        case tooLarge
        case writeFailed
    }

    static let maxBytes = 10 * 1024 * 1024

    static func stage(data: Data, projectId: String, root: URL = Paths.projectIconsRoot) throws -> Staged {
        guard data.count <= maxBytes else { throw StagingError.tooLarge }
        guard let ext = fileExtension(for: data) else { throw StagingError.unsupportedFormat }

        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let filename = "\(hash).\(ext)"
        let dir = root.appendingPathComponent(projectId, isDirectory: true)
        let url = dir.appendingPathComponent(filename)

        do {
            try Paths.ensureDirectoryExists(dir)
            if !FileManager.default.fileExists(atPath: url.path) {
                try data.write(to: url, options: .atomic)
            }
            return Staged(imagePath: "\(projectId)/\(filename)", url: url)
        } catch {
            throw StagingError.writeFailed
        }
    }

    static func validateFileSize(at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey])
        let size = values.fileSize ?? values.totalFileAllocatedSize
        if let size, size > maxBytes {
            throw StagingError.tooLarge
        }
    }

    static func url(for imagePath: String, root: URL = Paths.projectIconsRoot) -> URL {
        root.appendingPathComponent(imagePath)
    }

    static func fileExtension(for data: Data) -> String? {
        let b = [UInt8](data.prefix(16))
        if b.count >= 8, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return "png" }
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return "jpg" }
        if b.count >= 6, b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 { return "gif" }
        if b.count >= 12, b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return "webp" }
        return nil
    }
}

extension ProjectIconImageStaging.StagingError {
    var userMessage: String {
        switch self {
        case .unsupportedFormat: return "That image format isn't supported (use PNG, JPEG, GIF, or WebP)."
        case .tooLarge: return "That image is too large (max 10 MB)."
        case .writeFailed: return "Couldn't save that project icon. Please try again."
        }
    }
}
