import Foundation

enum ImageFileType {
    static let supportedExtensions: Set<String> = [
        "png",
        "jpg",
        "jpeg",
        "gif",
        "tiff",
        "tif",
        "bmp",
        "heic",
        "heif",
        "webp",
        "svg",
    ]

    static func isSupported(relativePath: String) -> Bool {
        guard let ext = fileExtension(relativePath: relativePath) else { return false }
        return supportedExtensions.contains(ext)
    }

    static func isSupported(currentPath: String, originalPath: String?) -> Bool {
        isSupported(relativePath: currentPath)
            || originalPath.map(isSupported(relativePath:)) == true
    }

    static func isTextBacked(relativePath: String) -> Bool {
        fileExtension(relativePath: relativePath) == "svg"
    }

    static func fileExtension(relativePath: String) -> String? {
        let ext = (relativePath as NSString).pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ext.isEmpty else { return nil }
        return ext.lowercased()
    }
}
