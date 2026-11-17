import AlasHighlight
import SwiftUI
import UIKit

/// A fenced code block: language label and Copy above the highlighted code, as on the Mac.
struct CodeBlockView: View {
    let language: String?
    let chunks: [CodeChunk]
    @Environment(\.colorScheme) private var colorScheme
    @State private var copied = false

    var body: some View {
        let tokens = ThemeTokens.forScheme(colorScheme)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let language, !language.isEmpty {
                    Text(language).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(action: copy) {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(chunks.enumerated()), id: \.offset) { _, chunk in
                    Text(tokens.attributed(chunk))
                }
            }
            .font(.system(.footnote, design: .monospaced))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private func copy() {
        UIPasteboard.general.string = chunks.map(\.text).joined(separator: "\n")
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

/// The Mac's theme colours, read from its bundled theme files, so code reads the same on both.
struct ThemeTokens {
    private let colors: [String: Color]

    static let light = ThemeTokens(resource: "light")
    static let dark = ThemeTokens(resource: "cool-slate")

    static func forScheme(_ scheme: ColorScheme) -> ThemeTokens {
        scheme == .dark ? dark : light
    }

    private init(resource: String) {
        struct File: Decodable { let tokens: [String: String] }
        let file = Bundle.main.url(forResource: resource, withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(File.self, from: $0) }
        colors = (file?.tokens ?? [:]).compactMapValues { value in
            guard let rgb = try? OKLCH.parse(value).linearSRGB() else { return nil }
            return Color(.sRGBLinear, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: rgb.alpha)
        }
    }

    func attributed(_ chunk: CodeChunk) -> AttributedString {
        var out = AttributedString(chunk.text)
        out.foregroundColor = colors["fg"]
        for span in chunk.spans {
            // Every span paints, so a plain capture nested in a coloured one (a string's
            // interpolated name) returns to the foreground, as on the Mac.
            if let color = span.capture.themeToken.flatMap({ colors[$0] }) ?? colors["fg"],
               let range = Range(span.range, in: out) {
                out[range].foregroundColor = color
            }
        }
        return out
    }
}
