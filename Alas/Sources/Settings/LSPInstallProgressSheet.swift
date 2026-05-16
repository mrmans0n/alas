import SwiftUI

struct LSPInstallProgressSheet: View {
    @Bindable var installer: LSPInstaller
    /// Called when the user dismisses the sheet via Close/Done. The argument
    /// carries the language whose install just succeeded, so callers can
    /// re-open any editor buffers using that language. Nil on cancel,
    /// failure, or close-before-finish.
    let onDone: (_ completedLanguage: String?) -> Void

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
                    AlasButton(title: "Close", style: .subtle, action: dismissCarryingCompletion)
                    if isSuccess {
                        AlasButton(title: "Done", style: .primary, action: dismissCarryingCompletion)
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

    /// Snapshot the completed language (if any) BEFORE `reset()` flips state
    /// back to `.idle` and drops its associated value, then reset and notify
    /// the caller. Used by both the Close and Done buttons so dismissing via
    /// either still triggers the post-install reopen of editor buffers.
    private func dismissCarryingCompletion() {
        let completed: String?
        if case .finished(let lang, 0) = installer.state {
            completed = lang
        } else {
            completed = nil
        }
        installer.reset()
        onDone(completed)
    }
}
