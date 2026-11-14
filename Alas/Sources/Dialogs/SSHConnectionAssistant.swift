import SwiftUI
import AppKit

struct SSHConnectionIssue {
    enum Kind: Equatable {
        case needsInteraction
        case nonInteractiveUnavailable
    }

    let kind: Kind
    let detail: String

    var title: String {
        switch kind {
        case .needsInteraction:
            "SSH connection needs attention"
        case .nonInteractiveUnavailable:
            "Non-interactive SSH is unavailable"
        }
    }

    var message: String {
        switch kind {
        case .needsInteraction:
            "Connect in an Alas terminal to accept host keys or complete authentication."
        case .nonInteractiveUnavailable:
            "Alas connected interactively, but the server still rejected the non-interactive channel required for remote projects. The account may require a terminal for every command."
        }
    }
}

enum SSHSetupStatus: Equatable {
    case connecting
    case verifying
    case failed(String)
    case incompatible(String)
}

/// Drives the interactive first SSH contact (host keys, passwords, 2FA) in a
/// transient terminal, then waits for the reusable control connection.
@MainActor
@Observable
final class SSHConnectionSetup {
    var isPresented = false
    private(set) var status: SSHSetupStatus = .connecting
    private(set) var surface: AlasGhostty.SurfaceView?
    private var attemptID = UUID()

    /// Opens the assistant for `host`. Returns an error message when the
    /// terminal cannot be opened. `onConnected` runs once the non-interactive
    /// connection is ready.
    func start(
        host: String,
        state: AppState,
        theme: Theme,
        onConnected: @escaping @MainActor () async -> Void
    ) -> String? {
        let attemptID = UUID()
        self.attemptID = attemptID
        status = .connecting
        let invocation = RemoteRepoValidator.interactiveSetupInvocation(host: host)
        do {
            surface = try state.terminal.makeTransientSurface(
                cfg: state.config.terminal,
                theme: theme,
                executable: invocation.executable,
                args: invocation.args,
                onExit: { [weak self] in
                    Task { @MainActor in
                        self?.handleExit(attemptID: attemptID, host: host, onConnected: onConnected)
                    }
                }
            )
            isPresented = true
            return nil
        } catch {
            return "Could not open the SSH connection terminal: \(error.localizedDescription)"
        }
    }

    func markIncompatible(_ message: String) {
        status = .incompatible(message)
    }

    func dismiss() {
        attemptID = UUID()
        surface?.processExitHandler = nil
        surface = nil
        if status == .verifying {
            status = .connecting
        }
    }

    private func handleExit(attemptID: UUID, host: String, onConnected: @escaping @MainActor () async -> Void) {
        guard self.attemptID == attemptID, status == .connecting else { return }
        status = .verifying
        Task {
            let connected = await RemoteRepoValidator.waitForActiveControlMaster(host: host)
            guard self.attemptID == attemptID else { return }
            guard connected else {
                status = .failed(
                    "SSH did not establish a reusable connection. Review the terminal output and retry."
                )
                return
            }
            await onConnected()
        }
    }
}

struct SSHConnectionAssistant: View {
    @Environment(\.designScale) private var scale
    let host: String
    let surface: AlasGhostty.SurfaceView?
    let status: SSHSetupStatus
    let onCancel: () -> Void
    let onRetry: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        DialogContainer(
            title: "Connect to \(host)",
            subtitle: "Complete the SSH prompts below. Alas will continue when the connection is ready.",
            width: 760,
            content: {
                Group {
                    if let surface {
                        // Opaque even when terminal materials make Ghostty's
                        // default background transparent.
                        GhosttyHost(surface: surface)
                            .background(theme.color("bg-0"))
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(height: 380)
                .background(Color.black)
                .overlay(
                    RoundedRectangle(cornerRadius: scale.radius.small)
                        .strokeBorder(theme.color("line"), lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: scale.radius.small))

                statusView
            },
            cancelTitle: "Cancel",
            confirmTitle: confirmTitle,
            confirmStyle: confirmEnabled ? .primary : .normal,
            onCancel: onCancel,
            onConfirm: confirmAction,
            confirmEnabled: confirmEnabled
        )
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .connecting:
            Label("Waiting for SSH", systemImage: "terminal")
                .foregroundColor(theme.color("fg-muted"))
        case .verifying:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Verifying the non-interactive connection…")
            }
            .foregroundColor(theme.color("fg-muted"))
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundColor(.red)
        case .incompatible(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundColor(.red)
        }
    }

    private var confirmTitle: String {
        switch status {
        case .failed: "Retry"
        case .incompatible: "Close"
        case .connecting, .verifying: "Waiting…"
        }
    }

    private var confirmEnabled: Bool {
        switch status {
        case .failed, .incompatible: true
        case .connecting, .verifying: false
        }
    }

    private func confirmAction() {
        switch status {
        case .failed: onRetry()
        case .incompatible: onCancel()
        case .connecting, .verifying: break
        }
    }
}
