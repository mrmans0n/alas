import Foundation

enum BinaryFileType {
    /// Extensions that are unambiguously binary and not text- or image-backed.
    /// Kept disjoint from `ImageFileType.supportedExtensions`.
    static let knownBinaryExtensions: Set<String> = [
        "pdf",
        "mp4",
        "mov",
        "m4v",
        "avi",
        "zip",
        "tar",
        "gz",
        "tgz",
        "bz2",
        "xz",
        "7z",
        "rar",
        "dmg",
        "iso",
        "exe",
        "class",
        "jar",
        "war",
        "o",
        "a",
        "dylib",
        "so",
        "framework",
        "bin",
    ]

    static func isKnownBinary(relativePath: String) -> Bool {
        guard let ext = fileExtension(relativePath: relativePath) else { return false }
        return knownBinaryExtensions.contains(ext)
    }

    static func fileExtension(relativePath: String) -> String? {
        let ext = (relativePath as NSString).pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ext.isEmpty else { return nil }
        return ext.lowercased()
    }
}
