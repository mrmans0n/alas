import SwiftUI

/// Bottom-anchored live tail of a single ACP terminal. Raw pipe chunks are
/// parsed incrementally by `ACPTerminal`; this view receives a bounded tail
/// at display rate. Max height is 300 px.
struct ACPTerminalTailView: View {
    let terminalId: String
    let host: ACPTerminalHost
    @Environment(\.theme) private var theme

    var body: some View {
        if let terminal = host.terminal(id: terminalId) {
            TerminalLiveBody(terminal: terminal)
        } else {
            Text("Terminal output not retained across restart.")
                .font(.system(size: 11))
                .foregroundStyle(theme.color("fg-faint"))
                .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }
}

private struct TerminalLiveBody: View {
    @ObservedObject var terminal: ACPTerminal
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(parsedAttributed())
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 8)
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
            var font = Font.system(size: 11.5, design: .monospaced)
            if run.attributes.bold {
                font = .system(size: 11.5, weight: .bold, design: .monospaced)
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
        HStack(spacing: 6) {
            if let sig = s.signal {
                Text("Killed (\(sig))")
                    .foregroundStyle(theme.color("fg-faint"))
            } else if let code = s.exitCode {
                Text("Exited \(code)")
                    .foregroundStyle(code == 0 ? theme.color("add") : theme.color("del"))
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12).padding(.bottom, 6)
    }
}

private extension ANSIColor {
    func swiftUIColor(theme: Theme) -> Color? {
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
