import Foundation

/// File-type detection for markdown documents and standalone Mermaid files.
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

    static func isStandaloneMermaid(relativePath: String) -> Bool {
        let ext = ((relativePath as NSString).pathExtension).lowercased()
        return ext == "mmd" || ext == "mermaid"
    }

    static func supportsRichPreview(relativePath: String) -> Bool {
        isMarkdown(relativePath: relativePath) || isStandaloneMermaid(relativePath: relativePath)
    }
}
