import SwiftUI

/// Progress for the Homebrew self-update. Shows plain-language steps; the raw
/// brew log stays behind "Show details" and opens itself when something fails.
struct UpdateProgressSheet: View {
    @Bindable var updater: SelfUpdater
    let update: ReleaseInfo?
    /// False when brew succeeded but the bundle on disk is still the old
    /// release, because the tap hasn't picked up the new version yet.
    let isInstalled: Bool
    let onRetry: () -> Void
    let onRelaunch: () -> Void
    let onDone: () -> Void
    @Environment(\.theme) var theme
    @State private var showsDetails = false

    private let manualCommand = SelfUpdateCommand.homebrew.displayCommandLine

    private var updateName: String {
        switch update {
        case .stable(let release): return "Alas \(release.version.description)"
        case .nightly(let release): return "Nightly \(release.shortSHA)"
        case nil: return "The update"
        }
    }

    private var titleText: String {
        switch updater.state {
        case .idle, .running:
            return "Updating Alas…"
        case .finished(0):
            return isInstalled ? "\(updateName) is ready" : "Homebrew doesn't have \(updateName) yet"
        case .finished:
            return "Update failed"
        case .cancelled:
            return "Update cancelled"
        case .failed:
            return "Couldn't start the update"
        }
    }

    private var isRunning: Bool {
        switch updater.state {
        case .idle, .running: return true
        default: return false
        }
    }

    private var isSuccess: Bool {
        updater.state == .finished(exitCode: 0) && isInstalled
    }

    private var isNotPublishedYet: Bool {
        updater.state == .finished(exitCode: 0) && !isInstalled
    }

    private var isFailure: Bool {
        !isRunning && !isSuccess && !isNotPublishedYet
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if isSuccess {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(theme.color("add"))
                }
                Text(titleText)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.color("fg"))
            }
            .padding(.bottom, 8)

            status
                .padding(.bottom, 12)

            if !updater.logLines.isEmpty {
                detailsToggle
                if showsDetails {
                    log.padding(.top, 8)
                }
            }

            actionRow
                .padding(.top, 16)
        }
        .padding(22)
        .frame(width: 520)
        .background(theme.color("bg-1"))
        .interactiveDismissDisabled(true)
        .onChange(of: isFailure) { _, failed in
            if failed { showsDetails = true }
        }
    }

    @ViewBuilder private var status: some View {
        if isRunning {
            VStack(alignment: .leading, spacing: 6) {
                Text(updater.currentStepTitle.map { "\($0)…" } ?? "Starting…")
                    .font(.system(size: 12))
                    .foregroundColor(theme.color("fg-dim"))
                ProgressView()
                    .progressViewStyle(.linear)
            }
        } else if isSuccess {
            Text("Relaunch to switch to the new version. Terminals keep running.")
                .font(.system(size: 12))
                .foregroundColor(theme.color("fg-dim"))
        } else if isNotPublishedYet {
            Text("New releases take a few minutes to reach the Homebrew tap. Try again shortly.")
                .font(.system(size: 12))
                .foregroundColor(theme.color("fg-dim"))
        } else {
            VStack(alignment: .leading, spacing: 4) {
                if case .failed(let message) = updater.state {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundColor(theme.color("fg"))
                        .textSelection(.enabled)
                }
                Text("You can also run it manually in a terminal:")
                    .font(.system(size: 12))
                    .foregroundColor(theme.color("fg-dim"))
                Text(manualCommand)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(theme.color("fg"))
                    .textSelection(.enabled)
            }
        }
    }

    private var detailsToggle: some View {
        Button {
            showsDetails.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: showsDetails ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                Text(showsDetails ? "Hide details" : "Show details")
                    .font(.system(size: 12))
            }
            .foregroundColor(theme.color("fg-dim"))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var log: some View {
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
                .textSelection(.enabled)
                .padding(8)
            }
            .frame(height: 220)
            .background(theme.color("bg-0"))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(theme.color("line"), lineWidth: 0.5))
            .onAppear { proxy.scrollTo(updater.logLines.count - 1, anchor: .bottom) }
            .onChange(of: updater.logLines.count) { _, newCount in
                guard newCount > 0 else { return }
                proxy.scrollTo(newCount - 1, anchor: .bottom)
            }
        }
    }

    @ViewBuilder private var actionRow: some View {
        HStack(spacing: 8) {
            if isFailure, !updater.logLines.isEmpty {
                AlasButton(title: "Copy Log", style: .subtle) {
                    Clipboard.copy(updater.logLines.joined(separator: "\n"))
                }
            }
            Spacer()
            if isRunning {
                AlasButton(title: "Cancel", style: .subtle) {
                    updater.cancel()
                }
            } else if isSuccess {
                AlasButton(title: "Later", style: .subtle, action: onDone)
                AlasButton(title: "Relaunch Now", style: .primary, action: onRelaunch)
            } else {
                AlasButton(title: "Close", style: .subtle, action: onDone)
                AlasButton(title: "Retry", style: .primary, action: onRetry)
            }
        }
    }
}
