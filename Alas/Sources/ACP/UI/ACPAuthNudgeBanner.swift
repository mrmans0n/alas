import SwiftUI

struct ACPAuthTerminalCommand: Equatable {
    let command: String
    let args: [String]
    let env: [String: String]

    static func resolve(
        method: ACPInitializeResult.ACPAuthMethod,
        launchSpec: ACPLaunchSpec
    ) -> ACPAuthTerminalCommand? {
        guard method.kind == .terminal else { return nil }
        let env = method.env ?? [:]
        if let command = method.terminalAuth?.command?.trimmingCharacters(in: .whitespacesAndNewlines),
           !command.isEmpty {
            return ACPAuthTerminalCommand(
                command: command,
                args: method.terminalAuth?.args ?? method.args ?? [],
                env: env
            )
        }
        let fallbackCommand = launchSpec.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fallbackCommand.isEmpty else { return nil }
        return ACPAuthTerminalCommand(
            command: fallbackCommand,
            args: launchSpec.arguments + (method.args ?? []),
            env: launchSpec.extraEnv.merging(env) { _, methodValue in methodValue }
        )
    }
}

enum ACPAuthNudgeBannerCopy {
    static func message(agentDisplayName: String, reason: String?) -> String {
        let base = "\(agentDisplayName) needs sign-in before it can continue."
        guard let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reason.isEmpty
        else { return base }
        return "\(base) \(reason)"
    }

    static func unsupportedMessage(agentDisplayName: String) -> String {
        "\(agentDisplayName) requires environment credentials or agent sign-in, and sign-in is not supported yet. Add credentials outside Alas, then reconnect."
    }

    static func buttonTitle(method: ACPInitializeResult.ACPAuthMethod) -> String {
        if let label = method.terminalAuth?.label?.trimmingCharacters(in: .whitespacesAndNewlines),
           !label.isEmpty {
            return label
        }
        let name = method.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Sign In" : name
    }
}

struct ACPAuthNudgeBanner: View {
    let agentDisplayName: String
    let methods: [ACPInitializeResult.ACPAuthMethod]
    let reason: String?
    let onSignIn: (ACPInitializeResult.ACPAuthMethod) -> Void
    let onReconnect: () -> Void

    @Environment(\.theme) private var theme

    private var terminalMethod: ACPInitializeResult.ACPAuthMethod? {
        methods.first { $0.kind == .terminal }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.badge.key")
                .font(.system(size: 11))
                .foregroundStyle(theme.color("fg-faint"))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(theme.color("fg-muted"))
                .textSelection(.enabled)
            Spacer()
            if let terminalMethod {
                Button(ACPAuthNudgeBannerCopy.buttonTitle(method: terminalMethod)) {
                    onSignIn(terminalMethod)
                }
            } else {
                Button("Reconnect") {
                    onReconnect()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.color("bg-1").opacity(0.6))
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.color("line")).frame(height: 0.5)
        }
    }

    private var message: String {
        if terminalMethod != nil {
            return ACPAuthNudgeBannerCopy.message(
                agentDisplayName: agentDisplayName,
                reason: reason
            )
        }
        return ACPAuthNudgeBannerCopy.unsupportedMessage(agentDisplayName: agentDisplayName)
    }
}
