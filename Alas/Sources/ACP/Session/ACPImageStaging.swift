import Foundation
import CryptoKit

/// Writes pasted/dropped/picked image bytes to a durable, content-addressed
/// file under Application Support so drafts, the queue, and the transcript
/// can all reference the same `file://` path. Sniffs the MIME from the bytes,
/// rejects non-images and oversized payloads.
enum ACPImageStaging {
    struct Staged: Equatable {
        let url: URL
        let mimeType: String
    }

    enum StagingError: Error, Equatable {
        case unsupportedFormat
        case tooLarge
        case tooManyImages
        case writeFailed
    }

    /// Hard ceiling on a single original image (≈20 MB).
    static let maxBytes = 20 * 1024 * 1024

    /// Accepted image MIME types.
    static let supportedMIMEs: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]

    static func stage(data: Data, into worktreeId: String) throws -> Staged {
        guard data.count <= maxBytes else { throw StagingError.tooLarge }
        guard let mime = sniffMIME(data), supportedMIMEs.contains(mime) else {
            throw StagingError.unsupportedFormat
        }
        let ext = fileExtension(forMIME: mime)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let dir = Paths.acpAttachmentsDir(forWorktreeId: worktreeId)
        do {
            try Paths.ensureDirectoryExists(dir)
            let url = dir.appendingPathComponent("\(hash).\(ext)")
            if !FileManager.default.fileExists(atPath: url.path) {
                try data.write(to: url, options: .atomic)
            }
            return Staged(url: url, mimeType: mime)
        } catch {
            throw StagingError.writeFailed
        }
    }

    /// Sniff a MIME type from magic bytes. Covers the four supported formats.
    static func sniffMIME(_ data: Data) -> String? {
        let b = [UInt8](data.prefix(16))
        if b.count >= 8, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return "image/png" }
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return "image/jpeg" }
        if b.count >= 6, b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 { return "image/gif" }
        if b.count >= 12, b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return "image/webp" }
        return nil
    }

    static func fileExtension(forMIME mime: String) -> String {
        switch mime {
        case "image/png": return "png"
        case "image/jpeg": return "jpg"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        default: return "img"
        }
    }
}

extension ACPImageStaging.StagingError {
    var userMessage: String {
        switch self {
        case .unsupportedFormat: return "That image format isn't supported (use PNG, JPEG, GIF, or WebP)."
        case .tooLarge: return "That image is too large (max 20 MB)."
        case .tooManyImages: return "You can attach up to 10 images per message."
        case .writeFailed: return "Couldn't save that image. Please try again."
        }
    }
}
