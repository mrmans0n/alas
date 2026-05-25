import AppKit
import CoreText
import SwiftUI

/// File-type icon lookup: filename overrides win over extension matches.
/// View wrapper is in the bottom of this file (added in Task 2).
enum FileTypeIcon {
    struct Info: Equatable {
        let symbol: String
        let hex: String       // 6-char RGB hex, no leading "#"
        let kind: Kind
        let style: Style
        enum Kind { case filename, ext, fallbackExt, generic, folderExact, folderSuffix, folderPath }
        enum Style { case nerdFont, text }
    }

    static let nerdFontName = "JetBrainsMonoNF-Regular"

    static func info(for filename: String) -> Info {
        let lower = filename.lowercased()

        if let hit = filenameTable[lower] {
            return Info(symbol: hit.symbol, hex: hit.hex, kind: .filename, style: .nerdFont)
        }

        guard let dot = lower.lastIndex(of: "."), dot != lower.startIndex else {
            // No extension at all (or leading-dot-only like ".unknownrc"
            // which has no second dot) → generic glyph.
            return Info(symbol: "\u{F15B}", hex: "7A8089", kind: .generic, style: .nerdFont)
        }
        let ext = String(lower[lower.index(after: dot)...])

        if let hit = extensionTable[ext] {
            return Info(symbol: hit.symbol, hex: hit.hex, kind: .ext, style: .nerdFont)
        }
        // Fallback: gray tile with the extension text truncated to 3 chars.
        let symbol = String(ext.prefix(3))
        return Info(symbol: symbol, hex: "7A8089", kind: .fallbackExt, style: .text)
    }

    // Hex colors are RGB without "#". Reuse Color(hex:) from RepoDot.swift.
    private static let extensionTable: [String: (symbol: String, hex: String)] = [
        "swift": ("\u{E699}", "F05138"),
        "kt":    ("\u{E634}", "A97BF3"),
        "kts":   ("\u{E634}", "A97BF3"),
        "java":  ("\u{E256}", "E76F00"),
        "rs":    ("\u{E68B}", "D97558"),
        "py":    ("\u{E606}", "3B6E9C"),
        "go":    ("\u{E627}", "4EC0D0"),
        "ts":    ("\u{E628}", "3178C6"),
        "mts":   ("\u{E628}", "3178C6"),
        "cts":   ("\u{E628}", "3178C6"),
        "tsx":   ("\u{E625}", "61DAFB"),
        "js":    ("\u{E60C}", "E0C33B"),
        "mjs":   ("\u{E60C}", "E0C33B"),
        "cjs":   ("\u{E60C}", "E0C33B"),
        "jsx":   ("\u{E625}", "61DAFB"),
        "vue":   ("\u{E6A0}", "42B883"),
        "svelte": ("\u{E697}", "FF3E00"),
        "dart":  ("\u{E64C}", "00A4DC"),
        "ex":    ("\u{E62D}", "7E57C2"),
        "exs":   ("\u{E653}", "7E57C2"),
        "hs":    ("\u{E61F}", "5D4F85"),
        "lhs":   ("\u{E61F}", "5D4F85"),
        "lua":   ("\u{E620}", "000080"),
        "clj":   ("\u{E642}", "91DC47"),
        "cljs":  ("\u{E642}", "91DC47"),
        "cljc":  ("\u{E642}", "91DC47"),
        "php":   ("\u{E608}", "777BB4"),
        "rb":    ("\u{E605}", "CC342D"),
        "jl":    ("\u{E624}", "9558B2"),
        "zig":   ("\u{E6A9}", "F7A41D"),
        "scala": ("\u{E68E}", "DC322F"),
        "nim":   ("\u{E677}", "FFC200"),
        "cr":    ("\u{E62F}", "000000"),
        "ml":    ("\u{E67A}", "EC6813"),
        "mli":   ("\u{E67A}", "EC6813"),
        "c":     ("\u{E649}", "5A89BF"),
        "h":     ("\u{E649}", "A87FC4"),
        "cpp":   ("\u{E646}", "5A89BF"),
        "cc":    ("\u{E646}", "5A89BF"),
        "cxx":   ("\u{E646}", "5A89BF"),
        "hpp":   ("\u{E646}", "A87FC4"),
        "hh":    ("\u{E646}", "A87FC4"),
        "hxx":   ("\u{E646}", "A87FC4"),
        "fs":    ("\u{F031B}", "378BBA"),
        "fsx":   ("\u{F031B}", "378BBA"),
        "cs":    ("\u{F031B}", "68217A"),
        "pl":    ("\u{E67E}", "39457E"),
        "pm":    ("\u{E67E}", "39457E"),
        "elm":   ("\u{E62C}", "60B5CC"),
        "purs":  ("\u{E630}", "14161A"),
        "r":     ("\u{F0C1F}", "276DC3"),

        "html":  ("\u{E60E}", "E36B3A"),
        "htm":   ("\u{E60E}", "E36B3A"),
        "css":   ("\u{E614}", "5FA7D6"),
        "scss":  ("\u{E603}", "CF649A"),
        "sass":  ("\u{E603}", "CF649A"),
        "less":  ("\u{F016E}", "1D365D"),
        "styl":  ("\u{E600}", "7AA86A"),
        "json":  ("\u{E60B}", "CBB04A"),
        "jsonc": ("\u{E60B}", "CBB04A"),
        "md":    ("\u{F48A}", "5A8FC4"),
        "mdx":   ("\u{F48A}", "5A8FC4"),
        "xml":   ("\u{F05C0}", "E36B3A"),
        "svg":   ("\u{E698}", "CBB04A"),
        "png":   ("\u{E60D}", "A87FC4"),
        "jpg":   ("\u{E60D}", "A87FC4"),
        "jpeg":  ("\u{E60D}", "A87FC4"),
        "gif":   ("\u{E60D}", "A87FC4"),
        "tiff":  ("\u{E60D}", "A87FC4"),
        "tif":   ("\u{E60D}", "A87FC4"),
        "bmp":   ("\u{E60D}", "A87FC4"),
        "heic":  ("\u{E60D}", "A87FC4"),
        "heif":  ("\u{E60D}", "A87FC4"),
        "webp":  ("\u{E60D}", "A87FC4"),
        "ico":   ("\u{E623}", "CBB04A"),
        "sql":   ("\u{EACE}", "5FA7D6"),
        "mysql": ("\u{E229}", "5FA7D6"),
        "tf":    ("\u{F1062}", "7B42BC"),
        "tfvars": ("\u{F1062}", "7B42BC"),
        "graphql": ("\u{E662}", "E10098"),
        "gql":   ("\u{E662}", "E10098"),
        "prisma": ("\u{E684}", "2D3748"),
        "proto": ("\u{F0A7D}", "5FA7D6"),

        "dockerfile": ("\u{E650}", "2496ED"),
        "gradle": ("\u{E660}", "02303A"),
        "bazel": ("\u{E63A}", "43A047"),
        "cmake": ("\u{E673}", "7A6A5A"),
        "make":  ("\u{E673}", "7A6A5A"),
        "lock":  ("\u{F023}", "7A6A5A"),
        "toml":  ("\u{E60B}", "9C7B56"),
        "yaml":  ("\u{E60B}", "9C7B56"),
        "yml":   ("\u{E60B}", "9C7B56"),
        "sh":    ("\u{EBCA}", "7AA86A"),
        "bash":  ("\u{EBCA}", "7AA86A"),
        "zsh":   ("\u{EBCA}", "7AA86A"),
        "fish":  ("\u{EBCA}", "7AA86A"),
        "ps1":   ("\u{EBC7}", "5391FE"),
        "psm1":  ("\u{EBC7}", "5391FE"),
        "env":   ("\u{EBCA}", "7AA86A"),

        "pdf":   ("\u{F1C1}", "CC342D"),
        "zip":   ("\u{F410}", "7A6A5A"),
        "txt":   ("\u{F15C}", "7A7A7A"),
    ]

    private static let filenameTable: [String: (symbol: String, hex: String)] = [
        "cargo.toml":          ("\u{E68B}", "D97558"),
        "cargo.lock":          ("\u{E68B}", "7A6A5A"),
        "rust-toolchain.toml": ("\u{E68B}", "D97558"),
        "package.json":        ("\u{E616}", "CB3837"),
        "package-lock.json":   ("\u{E616}", "CB3837"),
        "npm-shrinkwrap.json": ("\u{E616}", "CB3837"),
        "yarn.lock":           ("\u{EF75}", "2C8EBB"),
        "pnpm-lock.yaml":      ("\u{E616}", "F69220"),
        "tsconfig.json":       ("\u{E628}", "3178C6"),
        "jsconfig.json":       ("\u{E60C}", "E0C33B"),
        ".gitignore":          ("\u{E65D}", "F05033"),
        ".gitattributes":      ("\u{E65D}", "F05033"),
        ".gitmodules":         ("\u{E65D}", "F05033"),
        ".github":             ("\u{EA84}", "7A8089"),
        ".gitlab-ci.yml":      ("\u{F296}", "FC6D26"),
        "readme.md":           ("\u{F48A}", "5A8FC4"),
        "license":             ("\u{F02D}", "9C8E6E"),
        "dockerfile":          ("\u{E650}", "2496ED"),
        "docker-compose.yml":  ("\u{E650}", "2496ED"),
        "docker-compose.yaml": ("\u{E650}", "2496ED"),
        "go.mod":              ("\u{E627}", "4EC0D0"),
        "go.sum":              ("\u{E627}", "4EC0D0"),
        "gemfile":             ("\u{E605}", "CC342D"),
        "rakefile":            ("\u{E604}", "CC342D"),
        "mix.exs":             ("\u{E62D}", "7E57C2"),
        "makefile":            ("\u{E673}", "7A6A5A"),
        "cmakelists.txt":      ("\u{E673}", "7A6A5A"),
    ]

    // MARK: - Folder icon lookup

    /// Returns icon info for semantically meaningful folders, or `nil` for
    /// generic folders that should keep the default folder icon.
    static func folderInfo(name: String, path: String? = nil) -> Info? {
        // 1. Path-aware matches (folder name alone is too ambiguous).
        if let path = path?.lowercased() {
            for entry in folderPathSuffixes {
                if pathMatchesSegmentSuffix(path, entry.pathSuffix) {
                    return Info(symbol: entry.symbol, hex: entry.hex, kind: .folderPath, style: .nerdFont)
                }
            }
        }

        let lower = name.lowercased()

        // 2. Exact folder-name match.
        if let hit = folderTable[lower] {
            return Info(symbol: hit.symbol, hex: hit.hex, kind: .folderExact, style: .nerdFont)
        }

        // 3. Suffix-pattern match (e.g. *.xcodeproj).
        for entry in folderSuffixes {
            if lower.hasSuffix(entry.suffix) {
                return Info(symbol: entry.symbol, hex: entry.hex, kind: .folderSuffix, style: .nerdFont)
            }
        }

        return nil
    }

    private static let folderTable: [String: (symbol: String, hex: String)] = [
        ".github":      ("\u{EA84}", "7A8089"),  // GitHub
        ".gitlab":      ("\u{F296}",  "FC6D26"),  // GitLab
        ".git":         ("\u{E65D}", "F05033"),  // Git
        ".vscode":      ("\u{E70C}", "007ACC"),  // VS Code
        ".idea":        ("\u{E7B5}", "A97BF3"),  // JetBrains
        "node_modules": ("\u{E718}", "68A063"),  // Node.js
        ".gradle":      ("\u{E660}", "02303A"),  // Gradle
        ".docker":      ("\u{E650}", "2496ED"),  // Docker
        "docker":       ("\u{E650}", "2496ED"),  // Docker assets
        ".circleci":    ("\u{E63E}", "343434"),  // CircleCI
    ]

    private static let folderSuffixes: [(suffix: String, symbol: String, hex: String)] = [
        (".xcodeproj",   "\u{E711}", "A2AAAD"),  // Xcode project
        (".xcworkspace", "\u{E711}", "A2AAAD"),  // Xcode workspace
        (".framework",   "\u{E711}", "A2AAAD"),  // Apple framework
        (".app",         "\u{E711}", "A2AAAD"),  // macOS app bundle
    ]

    private static let folderPathSuffixes: [(pathSuffix: String, symbol: String, hex: String)] = [
        ("src/main/resources", "\u{E256}", "E76F00"),  // Java resources
        ("src/test/resources", "\u{E256}", "E76F00"),  // Java test resources
    ]

    private static func pathMatchesSegmentSuffix(_ path: String, _ suffix: String) -> Bool {
        let normalizedPath = path.replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedSuffix = suffix.replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        return normalizedPath == normalizedSuffix || normalizedPath.hasSuffix("/" + normalizedSuffix)
    }
}

/// Square tile with the file-type glyph.
struct FileTypeIconView: View {
    let filename: String
    var size: CGFloat = 18
    @Environment(\.theme) private var theme

    var body: some View {
        let info = FileTypeIcon.info(for: filename)
        switch info.style {
        case .nerdFont:
            NerdFontGlyphView(symbol: info.symbol, hex: info.hex)
                .frame(width: size, height: size)
        case .text:
            let color = Color(hex: info.hex)
            Text(info.symbol)
                .font(.custom(FileTypeIcon.nerdFontName, size: fontPx(for: info.symbol)))
                .foregroundColor(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
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
        case 1:  scale = 0.72
        case 2:  scale = 0.60
        default: scale = 0.48  // 3+
        }
        return max(8, (size * scale).rounded())
    }
}

/// Renders a Nerd Font glyph for semantically meaningful folders,
/// falling back to the standard SF Symbol folder icon for generic ones.
struct FolderIconView: View {
    let name: String
    let path: String
    let open: Bool
    let fallbackColor: Color
    var size: CGFloat = 18

    var body: some View {
        Group {
            if let info = FileTypeIcon.folderInfo(name: name, path: path) {
                NerdFontGlyphView(symbol: info.symbol, hex: info.hex)
            } else {
                Icon(name: "folder", size: 11, color: fallbackColor)
            }
        }
        .frame(width: size, height: size)
    }
}

private struct NerdFontGlyphView: NSViewRepresentable {
    let symbol: String
    let hex: String

    func makeNSView(context: Context) -> GlyphDrawingView {
        let view = GlyphDrawingView()
        view.symbol = symbol
        view.hex = hex
        return view
    }

    func updateNSView(_ nsView: GlyphDrawingView, context: Context) {
        nsView.symbol = symbol
        nsView.hex = hex
    }
}

private final class GlyphDrawingView: NSView {
    var symbol: String = "" {
        didSet { needsDisplay = true }
    }

    var hex: String = "7A8089" {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext,
              let path = NerdFontGlyphPath.path(for: symbol) else {
            return
        }

        let bounds = path.boundingBoxOfPath
        guard bounds.width > 0, bounds.height > 0 else { return }

        let inset = max(1, min(self.bounds.width, self.bounds.height) * 0.06)
        let target = self.bounds.insetBy(dx: inset, dy: inset)
        let scale = min(target.width / bounds.width, target.height / bounds.height)
        let scaledWidth = bounds.width * scale
        let scaledHeight = bounds.height * scale

        context.saveGState()
        context.setFillColor(NSColor(hex: hex).cgColor)
        context.translateBy(
            x: target.midX - scaledWidth / 2 - bounds.minX * scale,
            y: target.midY + scaledHeight / 2 + bounds.minY * scale
        )
        context.scaleBy(x: scale, y: -scale)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
    }
}

enum NerdFontGlyphPath {
    static func path(for symbol: String) -> CGPath? {
        guard !symbol.isEmpty else { return nil }

        let font = CTFontCreateWithName(FileTypeIcon.nerdFontName as CFString, 1000, nil)
        let attributed = NSAttributedString(
            string: symbol,
            attributes: [kCTFontAttributeName as NSAttributedString.Key: font]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        let combined = CGMutablePath()

        for run in runs {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = attributes[kCTFontAttributeName] as! CTFont
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }

            var glyphs = Array(repeating: CGGlyph(), count: count)
            var positions = Array(repeating: CGPoint.zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)

            for index in 0..<count {
                guard let glyphPath = CTFontCreatePathForGlyph(runFont, glyphs[index], nil) else {
                    continue
                }
                let transform = CGAffineTransform(
                    translationX: positions[index].x,
                    y: positions[index].y
                )
                combined.addPath(glyphPath, transform: transform)
            }
        }

        return combined.isEmpty ? nil : combined
    }
}

private extension NSColor {
    convenience init(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        var int: UInt64 = 0
        Scanner(string: s).scanHexInt64(&int)
        let r = CGFloat((int >> 16) & 0xff) / 255.0
        let g = CGFloat((int >> 8) & 0xff) / 255.0
        let b = CGFloat(int & 0xff) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
