import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform

public enum ImageFileType: Sendable {
    public static let supportedExtensions: Set<String> = [
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

    public static func isSupported(relativePath: String) -> Bool {
        guard let ext = fileExtension(relativePath: relativePath) else { return false }
        return supportedExtensions.contains(ext)
    }

    public static func isSupported(currentPath: String, originalPath: String?) -> Bool {
        isSupported(relativePath: currentPath)
            || originalPath.map(isSupported(relativePath:)) == true
    }

    public static func isTextBacked(relativePath: String) -> Bool {
        fileExtension(relativePath: relativePath) == "svg"
    }

    public static func fileExtension(relativePath: String) -> String? {
        let ext = (relativePath as NSString).pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ext.isEmpty else { return nil }
        return ext.lowercased()
    }
}
