import AppKit
import SwiftUI

struct ACPSyntaxHighlightCacheKey: Equatable {
    let text: String
    let resolvedExtension: String?
    let themeKey: String
    let fontFamily: String
    let fontSize: CGFloat

    init(
        text: String,
        resolvedExtension: String?,
        theme: Theme,
        fontFamily: String = ACPChatTypography.default.fontFamily,
        fontSize: CGFloat
    ) {
        self.init(
            text: text,
            resolvedExtension: resolvedExtension,
            themeKey: Self.themeKey(theme),
            fontFamily: fontFamily,
            fontSize: fontSize
        )
    }

    init(
        text: String,
        resolvedExtension: String?,
        themeKey: String,
        fontFamily: String = ACPChatTypography.default.fontFamily,
        fontSize: CGFloat
    ) {
        self.text = text
        self.resolvedExtension = resolvedExtension
        self.themeKey = themeKey
        self.fontFamily = fontFamily
        self.fontSize = fontSize
    }

    static func themeKey(_ theme: Theme) -> String {
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
    private var cachedTheme: Theme?
    private var cachedThemeKey: String?

    func attributedString(
        text: String,
        explicitLanguage: String?,
        sourcePath: String?,
        theme: Theme,
        fontFamily: String,
        fontSize: CGFloat
    ) -> AttributedString {
        let resolvedExtension = explicitLanguage.flatMap(ACPCodeLanguage.highlighterExtension(for:))
            ?? ACPCodeLanguage.highlighterExtension(forPath: sourcePath)
        let themeKey = themeKey(for: theme)
        let nextKey = ACPSyntaxHighlightCacheKey(
            text: text,
            resolvedExtension: resolvedExtension,
            themeKey: themeKey,
            fontFamily: fontFamily,
            fontSize: fontSize
        )
        if key == nextKey, let value {
            return value
        }

        let highlighted = AttributedString(ACPCodeBlockHighlighter.attributedString(
            code: text,
            language: resolvedExtension,
            theme: theme,
            fontFamily: fontFamily,
            fontSize: fontSize
        ))
        key = nextKey
        value = highlighted
        return highlighted
    }

    private func themeKey(for theme: Theme) -> String {
        if cachedTheme == theme, let cachedThemeKey {
            return cachedThemeKey
        }
        let key = ACPSyntaxHighlightCacheKey.themeKey(theme)
        cachedTheme = theme
        cachedThemeKey = key
        return key
    }
}

struct ACPSyntaxHighlightedText: View {
    let text: String
    var explicitLanguage: String? = nil
    var sourcePath: String? = nil
    var fontFamily: String = ACPChatTypography.default.fontFamily
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
            fontFamily: fontFamily,
            fontSize: fontSize
        ))
        .font(Font(CenterTypography.resolveCodeFont(family: fontFamily, size: fontSize)))
        .foregroundStyle(theme.color("fg"))
        .lineSpacing(lineSpacing)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
