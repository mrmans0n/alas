import SwiftUI

/// File-type icon lookup: filename overrides win over extension matches.
/// View wrapper is in the bottom of this file (added in Task 2).
enum FileTypeIcon {
    struct Info: Equatable {
        let label: String
        let hex: String       // 6-char RGB hex, no leading "#"
        let kind: Kind
        enum Kind { case filename, ext, fallbackExt, generic }
    }

    static func info(for filename: String) -> Info {
        let lower = filename.lowercased()

        if let hit = filenameTable[lower] {
            return Info(label: hit.label, hex: hit.hex, kind: .filename)
        }

        guard let dot = lower.lastIndex(of: "."), dot != lower.startIndex else {
            // No extension at all (or leading-dot-only like ".unknownrc"
            // which has no second dot) → generic glyph.
            return Info(label: "", hex: "7A8089", kind: .generic)
        }
        let ext = String(lower[lower.index(after: dot)...])

        if let hit = extensionTable[ext] {
            return Info(label: hit.label, hex: hit.hex, kind: .ext)
        }
        // Fallback: gray tile with the extension text truncated to 3 chars.
        let label = String(ext.prefix(3))
        return Info(label: label, hex: "7A8089", kind: .fallbackExt)
    }

    // Hex colors are RGB without "#". Reuse Color(hex:) from RepoDot.swift.
    private static let extensionTable: [String: (label: String, hex: String)] = [
        "swift": ("swift", "F05138"),
        "rs":    ("rs",    "D97558"),
        "toml":  ("TM",    "9C7B56"),
        "lock":  ("\u{1F512}", "7A6A5A"),  // 🔒
        "md":    ("M\u{2193}", "5A8FC4"),  // M↓
        "mdx":   ("M\u{2193}", "5A8FC4"),
        "ts":    ("TS",    "3178C6"),
        "tsx":   ("TSX",   "3178C6"),
        "js":    ("JS",    "E0C33B"),
        "jsx":   ("JSX",   "61DAFB"),
        "json":  ("{}",    "CBB04A"),
        "html":  ("</>",   "E36B3A"),
        "css":   ("#",     "5FA7D6"),
        "scss":  ("#",     "CF649A"),
        "py":    ("py",    "3B6E9C"),
        "go":    ("go",    "4EC0D0"),
        "c":     ("C",     "5A89BF"),
        "h":     ("h",     "A87FC4"),
        "cpp":   ("C+",    "5A89BF"),
        "rb":    ("rb",    "CC342D"),
        "java":  ("JV",    "E76F00"),
        "kt":    ("kt",    "A97BF3"),
        "sh":    (">_",    "7AA86A"),
        "yaml":  ("YL",    "9C7B56"),
        "yml":   ("YL",    "9C7B56"),
        "svg":   ("svg",   "CBB04A"),
        "png":   ("png",   "A87FC4"),
        "jpg":   ("jpg",   "A87FC4"),
        "jpeg":  ("jpg",   "A87FC4"),
        "gif":   ("gif",   "A87FC4"),
        "webp":  ("wp",    "A87FC4"),
        "pdf":   ("PDF",   "CC342D"),
        "zip":   ("zip",   "7A6A5A"),
        "txt":   ("txt",   "7A7A7A"),
        "sql":   ("sql",   "5FA7D6"),
        "env":   ("env",   "7AA86A"),
    ]

    private static let filenameTable: [String: (label: String, hex: String)] = [
        "cargo.toml":          ("rs",  "D97558"),
        "cargo.lock":          ("rs",  "7A6A5A"),
        "package.json":        ("pk",  "CB3837"),
        "package-lock.json":   ("lk",  "CB3837"),
        "tsconfig.json":       ("ts",  "3178C6"),
        ".gitignore":          ("git", "F05033"),
        ".gitattributes":      ("git", "F05033"),
        "readme.md":           ("RM",  "5A8FC4"),
        "license":             ("LIC", "9C8E6E"),
        "dockerfile":          ("dk",  "2496ED"),
        "rust-toolchain.toml": ("rs",  "D97558"),
    ]
}

/// Square tile with the file-type glyph. For `.generic` kind, renders the
/// existing SF Symbol `doc` so files with no extension still get an icon.
struct FileTypeIconView: View {
    let filename: String
    var size: CGFloat = 13
    @Environment(\.theme) private var theme

    var body: some View {
        let info = FileTypeIcon.info(for: filename)
        switch info.kind {
        case .generic:
            Icon(name: "file", size: size, color: theme.color("fg-faint"))
        case .filename, .ext, .fallbackExt:
            let color = Color(hex: info.hex)
            Text(info.label)
                .font(.system(size: fontPx(for: info.label), weight: .bold, design: .monospaced))
                .foregroundColor(color)
                .kerning(-0.2)
                .lineLimit(1)
                .frame(width: size, height: size)
                .background(color.opacity(0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(color.opacity(0.25), lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        }
    }

    private func fontPx(for label: String) -> CGFloat {
        let chars = max(1, label.count)
        let scale: CGFloat
        switch chars {
        case 1:  scale = 0.60
        case 2:  scale = 0.52
        default: scale = 0.42  // 3+
        }
        return max(7, (size * scale).rounded())
    }
}
