import Foundation

/// File-type detection for markdown documents. Matches by extension
/// (`.md`, `.markdown`, `.mdx`, case-insensitive) and a small set of
/// extension-less conventional filenames found in source repos.
enum MarkdownFileType {
    private static let extensions: Set<String> = ["md", "markdown", "mdx"]
    private static let extensionlessNames: Set<String> = [
        "readme", "changelog", "contributing", "license", "notice", "authors"
    ]

    static func isMarkdown(relativePath: String) -> Bool {
        guard !relativePath.isEmpty else { return false }
        let filename = (relativePath as NSString).lastPathComponent
        let ext = (filename as NSString).pathExtension.lowercased()
        if !ext.isEmpty {
            return extensions.contains(ext)
        }
        return extensionlessNames.contains(filename.lowercased())
    }
}
