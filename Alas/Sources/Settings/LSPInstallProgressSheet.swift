import SwiftUI

struct LSPInstallProgressSheet: View {
    @Bindable var installer: LSPInstaller
    let onDone: () -> Void

    @Environment(\.theme) var theme

    private var titleText: String {
        switch installer.state {
        case .idle:
            return "Install language server"
        case .running(let lang, _):
            return "Installing \(lang)"
        case .finished(let lang, let exitCode):
            return exitCode == 0 ? "Installed \(lang)" : "Failed to install \(lang)"
        case .cancelled(let lang):
            return "Cancelled installing \(lang)"
        case .failed(let lang, _):
            return "Failed to install \(lang)"
        }
    }

    private var commandLine: String {
        if case .running(_, let cl) = installer.state { return cl }
        return ""
    }

    private var isRunning: Bool {
        if case .running = installer.state { return true } else { return false }
    }

    private var isSuccess: Bool {
        if case .finished(_, 0) = installer.state { return true } else { return false }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(titleText)
                .font(.system(size: 16, weight: .semibold))
                .padding(.bottom, 8)

            if !commandLine.isEmpty {
                Text(commandLine)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(theme.color("fg-dim"))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.color("bg-0"))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(theme.color("line"), lineWidth: 0.5))
                    .padding(.bottom, 12)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(installer.logLines.enumerated()), id: \.offset) { idx, line in
                            Text(line.isEmpty ? " " : line)
                                .font(.system(size: 11.5, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }
                    .padding(8)
                }
                .frame(height: 280)
                .background(theme.color("bg-0"))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(theme.color("line"), lineWidth: 0.5))
                .onChange(of: installer.logLines.count) { _, newCount in
                    guard newCount > 0 else { return }
                    proxy.scrollTo(newCount - 1, anchor: .bottom)
                }
            }

            HStack(spacing: 8) {
                Spacer()
                if isRunning {
                    AlasButton(title: "Cancel", style: .subtle) {
                        installer.cancel()
                    }
                } else {
                    AlasButton(title: "Close", style: .subtle) {
                        installer.reset()
                        onDone()
                    }
                    if isSuccess {
                        AlasButton(title: "Done", style: .primary) {
                            installer.reset()
                            onDone()
                        }
                    }
                }
            }
            .padding(.top, 16)
        }
        .padding(24)
        .frame(width: 600)
        .background(theme.color("bg-1"))
        .interactiveDismissDisabled(isRunning)
    }
}
