import SwiftUI

/// Bottom-anchored live tail of a single ACP terminal. Raw pipe chunks are
/// parsed incrementally by `ACPTerminal`; this view receives a bounded tail
/// at display rate. Max height is 300 px.
struct ACPTerminalTailView: View {
    @Environment(\.designScale) private var scale
    let terminalId: String
    let host: ACPTerminalHost
    @Environment(\.theme) private var theme

    var body: some View {
        if let terminal = host.terminal(id: terminalId) {
            TerminalLiveBody(terminal: terminal)
        } else {
            Text("Terminal output not retained across restart.")
                .font(scale.metaFont)
                .foregroundStyle(theme.color("fg-faint"))
                .padding(.horizontal, scale.space[3]).padding(.vertical, scale.space[2])
        }
    }
}

private struct TerminalLiveBody: View {
    @Environment(\.designScale) private var scale
    @ObservedObject var terminal: ACPTerminal
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: scale.space[1]) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(parsedAttributed())
                        .font(scale.meta.font(design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, scale.space[3]).padding(.vertical, scale.space[2])
                        .id("BOTTOM")
                }
                .frame(maxHeight: 300)
                .onChange(of: terminal.displayRevision) { _, _ in
                    proxy.scrollTo("BOTTOM", anchor: .bottom)
                }
            }
            if let s = terminal.exitStatus {
                exitFooter(s)
            }
        }
        .background(theme.color("bg-0").opacity(0.55))
    }

    private func parsedAttributed() -> AttributedString {
        let runs = terminal.displayRuns
        var out = AttributedString(runs.lazy.map(\.text).joined())
        var lowerBound = out.startIndex
        for run in runs where !run.text.isEmpty {
            let upperBound = out.characters.index(lowerBound, offsetBy: run.text.count)
            var font = scale.meta.font(design: .monospaced)
            if run.attributes.bold {
                font = scale.meta.font(weight: .bold, design: .monospaced)
            }
            if run.attributes.italic { font = font.italic() }
            out[lowerBound..<upperBound].font = font
            if let c = run.attributes.foreground.swiftUIColor(theme: theme) {
                out[lowerBound..<upperBound].foregroundColor = c
            } else {
                out[lowerBound..<upperBound].foregroundColor = theme.color("fg-muted")
            }
            if let bg = run.attributes.background.swiftUIColor(theme: theme) {
                out[lowerBound..<upperBound].backgroundColor = bg
            }
            if run.attributes.underline {
                out[lowerBound..<upperBound].underlineStyle = .single
            }
            lowerBound = upperBound
        }
        return out
    }

    @ViewBuilder
    private func exitFooter(_ s: ACPTerminalExitStatus) -> some View {
        HStack(spacing: scale.space[2]) {
            if let sig = s.signal {
                Text("Killed (\(sig))")
                    .foregroundStyle(theme.color("fg-faint"))
            } else if let code = s.exitCode {
                Text("Exited \(code)")
                    .foregroundStyle(code == 0 ? theme.color("add") : theme.color("del"))
            }
        }
        .font(scale.metaFont)
        .padding(.horizontal, scale.space[3]).padding(.bottom, scale.space[2])
    }
}

private extension ANSIColor {
    func swiftUIColor(theme: Theme) -> Color? {
        if !theme.darkMode, let index = paletteIndex {
            return Color(hex: ANSIColor.lightPalette[index])
        }
        switch self {
        case .default: return nil
        case .black: return .black
        case .red: return .red
        case .green: return .green
        case .yellow: return .yellow
        case .blue: return .blue
        case .magenta: return .purple
        case .cyan: return .cyan
        case .white: return .white
        case .brightBlack: return .gray
        case .brightRed: return Color(red: 1.0, green: 0.5, blue: 0.5)
        case .brightGreen: return Color(red: 0.5, green: 1.0, blue: 0.5)
        case .brightYellow: return Color(red: 1.0, green: 1.0, blue: 0.5)
        case .brightBlue: return Color(red: 0.5, green: 0.5, blue: 1.0)
        case .brightMagenta: return Color(red: 1.0, green: 0.5, blue: 1.0)
        case .brightCyan: return Color(red: 0.5, green: 1.0, blue: 1.0)
        case .brightWhite: return .white
        case .rgb(let r, let g, let b):
            return Color(red: Double(r) / 255.0, green: Double(g) / 255.0, blue: Double(b) / 255.0)
        }
    }
}
