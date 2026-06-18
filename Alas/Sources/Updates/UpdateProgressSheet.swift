import SwiftUI

struct UpdateProgressSheet: View {
    @Bindable var updater: SelfUpdater
    let onDone: () -> Void
    @Environment(\.theme) var theme

    private var titleText: String {
        switch updater.state {
        case .idle:
            return "Update Alas"
        case .running:
            return "Updating Alas…"
        case .finished(let exitCode):
            return exitCode == 0 ? "Update downloaded" : "Update failed"
        case .cancelled:
            return "Update cancelled"
        case .failed:
            return "Could not start update"
        }
    }

    private var commandLine: String {
        if case .running(let cl) = updater.state { return cl }
        return ""
    }

    private var isRunning: Bool {
        if case .running = updater.state { return true }
        return false
    }

    private var isSuccess: Bool {
        if case .finished(0) = updater.state { return true }
        return false
    }

    private var isFailure: Bool {
        switch updater.state {
        case .finished(let exitCode) where exitCode != 0:
            return true
        case .failed, .cancelled:
            return true
        default:
            return false
        }
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

            if isSuccess {
                Text("Quit and reopen Alas to start the new version.")
                    .font(.system(size: 12))
                    .foregroundColor(theme.color("fg"))
                    .padding(.bottom, 12)
            } else if isFailure {
                Text("You can also run the command manually in a terminal.")
                    .font(.system(size: 12))
                    .foregroundColor(theme.color("fg-dim"))
                    .padding(.bottom, 12)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(updater.logLines.enumerated()), id: \.offset) { idx, line in
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
                .onChange(of: updater.logLines.count) { _, newCount in
                    guard newCount > 0 else { return }
                    proxy.scrollTo(newCount - 1, anchor: .bottom)
                }
            }

            HStack(spacing: 8) {
                Spacer()
                if isRunning {
                    AlasButton(title: "Cancel", style: .subtle) {
                        updater.cancel()
                    }
                } else {
                    AlasButton(title: "Close", style: .subtle) {
                        updater.reset()
                        onDone()
                    }
                    if isSuccess {
                        AlasButton(title: "Done", style: .primary) {
                            updater.reset()
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
        .interactiveDismissDisabled(true)
    }
}
