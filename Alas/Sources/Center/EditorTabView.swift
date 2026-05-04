import SwiftUI

struct EditorTabView: View {
    let worktreePath: URL
    let relativePath: String
    @Environment(\.theme) var theme

    @State private var content: String = ""
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            breadcrumb
            ScrollView {
                ScrollView(.horizontal, showsIndicators: false) {
                    if loaded {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(content.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { (i, line) in
                                CodeLineView(number: i + 1, line: String(line), language: SimpleHighlighter.language(forFile: relativePath))
                            }
                        }
                        .padding(.vertical, 8)
                    } else {
                        ProgressView().padding()
                    }
                }
            }
        }
        .background(theme.color("bg-1"))
        .task { await load() }
    }

    private var breadcrumb: some View {
        HStack(spacing: 6) {
            ForEach(Array(relativePath.split(separator: "/").enumerated()), id: \.offset) { (i, comp) in
                Text(comp)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(i == relativePath.split(separator: "/").count - 1 ? theme.color("fg") : theme.color("fg-muted"))
                if i < relativePath.split(separator: "/").count - 1 {
                    Text("/").foregroundColor(theme.color("fg-faint"))
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12).frame(height: 28)
        .background(theme.color("bg-1"))
        .overlay(Divider().opacity(0.5), alignment: .bottom)
    }

    private func load() async {
        let url = worktreePath.appendingPathComponent(relativePath)
        if let data = try? Data(contentsOf: url),
           let str = String(data: data, encoding: .utf8) {
            content = str
        } else {
            content = "(unable to read file)"
        }
        loaded = true
    }
}

struct CodeLineView: View {
    let number: Int
    let line: String
    let language: String
    @Environment(\.theme) var theme

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text("\(number)")
                .frame(width: 44, alignment: .trailing)
                .foregroundColor(theme.color("fg-faint"))
            HStack(spacing: 0) {
                ForEach(Array(SimpleHighlighter.tokenize(line, language: language).enumerated()), id: \.offset) { (_, tok) in
                    Text(tok.text)
                        .foregroundColor(color(for: tok.kind))
                }
            }
        }
        .font(.system(size: 12.5, design: .monospaced))
        .padding(.horizontal, 14)
    }

    private func color(for kind: TokenKind) -> Color {
        switch kind {
        case .keyword:  return Color(hex: "#c79bff")
        case .type:     return Color(hex: "#7fc7e3")
        case .string:   return theme.color("add")
        case .number:   return theme.color("mod")
        case .comment:  return theme.color("fg-faint")
        case .function: return Color(hex: "#e6c98a")
        case .plain:    return theme.color("fg")
        }
    }
}
