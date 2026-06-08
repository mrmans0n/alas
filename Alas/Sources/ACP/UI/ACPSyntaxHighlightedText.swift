import AppKit
import SwiftUI

struct ACPSyntaxHighlightCacheKey: Equatable {
    let text: String
    let resolvedExtension: String?
    let themeKey: String
    let fontSize: CGFloat

    init(text: String, resolvedExtension: String?, theme: Theme, fontSize: CGFloat) {
        self.text = text
        self.resolvedExtension = resolvedExtension
        self.themeKey = Self.themeKey(theme)
        self.fontSize = fontSize
    }

    private static func themeKey(_ theme: Theme) -> String {
        let tokenKey = theme.tokens
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "|")
        let overrideKey = theme.resolvedColorOverrides
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(colorKey($0.value))" }
            .joined(separator: "|")
        return "id=\(theme.id)|accent=\(theme.accentOverrideHex ?? "")|tokens=\(tokenKey)|overrides=\(overrideKey)"
    }

    private static func colorKey(_ color: Color) -> String {
        let nsColor = NSColor(color)
        guard let normalized = nsColor.usingColorSpace(.sRGB) else {
            return nsColor.description
        }
        return String(
            format: "r=%.6f,g=%.6f,b=%.6f,a=%.6f",
            Double(normalized.redComponent),
            Double(normalized.greenComponent),
            Double(normalized.blueComponent),
            Double(normalized.alphaComponent)
        )
    }
}

@MainActor
private final class ACPSyntaxHighlightedTextCache: ObservableObject {
    private var key: ACPSyntaxHighlightCacheKey?
    private var value: AttributedString?

    func attributedString(
        text: String,
        explicitLanguage: String?,
        sourcePath: String?,
        theme: Theme,
        fontSize: CGFloat
    ) -> AttributedString {
        let resolvedExtension = explicitLanguage.flatMap(ACPCodeLanguage.highlighterExtension(for:))
            ?? ACPCodeLanguage.highlighterExtension(forPath: sourcePath)
        let nextKey = ACPSyntaxHighlightCacheKey(
            text: text,
            resolvedExtension: resolvedExtension,
            theme: theme,
            fontSize: fontSize
        )
        if key == nextKey, let value {
            return value
        }

        let highlighted = AttributedString(ACPCodeBlockHighlighter.attributedString(
            code: text,
            language: resolvedExtension,
            theme: theme,
            fontSize: fontSize
        ))
        key = nextKey
        value = highlighted
        return highlighted
    }
}

struct ACPSyntaxHighlightedText: View {
    let text: String
    var explicitLanguage: String? = nil
    var sourcePath: String? = nil
    var fontSize: CGFloat = 12
    var lineSpacing: CGFloat = 2

    @Environment(\.theme) private var theme
    @StateObject private var cache = ACPSyntaxHighlightedTextCache()

    var body: some View {
        Text(cache.attributedString(
            text: text,
            explicitLanguage: explicitLanguage,
            sourcePath: sourcePath,
            theme: theme,
            fontSize: fontSize
        ))
        .font(.system(size: fontSize, design: .monospaced))
        .foregroundStyle(theme.color("fg"))
        .lineSpacing(lineSpacing)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
