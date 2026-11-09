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

struct ACPAuthNudgeBanner: View {
    @Environment(\.designScale) private var scale
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
        HStack(spacing: scale.space[2]) {
            Image(systemName: "person.badge.key")
                .font(scale.metaFont)
                .foregroundStyle(theme.color("fg-faint"))
            Text(message)
                .font(scale.metaFont)
                .foregroundStyle(theme.color("fg-muted"))
                .textSelection(.enabled)
            Spacer()
            if let terminalMethod {
                Button(ACPAuthNudgeBannerCopy.buttonTitle(method: terminalMethod)) {
                    onSignIn(terminalMethod)
                }
            }
            Button("Reconnect") {
                onReconnect()
            }
        }
        .padding(.horizontal, scale.space[3])
        .padding(.vertical, scale.space[2])
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
