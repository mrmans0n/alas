import Foundation
import Testing
@testable import Alas

@Suite("ACPAuthNudgeBanner")
struct ACPAuthNudgeBannerTests {
    @Test("button label uses terminal-auth metadata label")
    func labelUsesTerminalMetadata() {
        let method = authMethod(
            name: "Claude Subscription",
            terminalAuth: .init(command: nil, args: nil, label: "Claude Login")
        )

        #expect(ACPAuthNudgeBannerCopy.buttonTitle(method: method) == "Claude Login")
    }

    @Test("unsupported env auth copy mentions environment credentials")
    func unsupportedEnvAuthCopy() {
        let message = ACPAuthNudgeBannerCopy.unsupportedMessage(agentDisplayName: "Cursor")

        #expect(message.contains("environment credentials"))
        #expect(message.contains("sign-in is not supported yet"))
    }

    @Test("command resolver prefers terminal-auth metadata command args and method env")
    func commandResolverPrefersTerminalMetadata() {
        let method = authMethod(
            args: ["ignored"],
            env: ["A": "B"],
            terminalAuth: .init(
                command: "/usr/bin/node",
                args: ["/opt/claude-agent-acp", "--cli"],
                label: "Claude Login"
            )
        )

        let command = ACPAuthTerminalCommand.resolve(method: method, fallbackCommand: "claude-agent-acp")

        #expect(command == ACPAuthTerminalCommand(
            command: "/usr/bin/node",
            args: ["/opt/claude-agent-acp", "--cli"],
            env: ["A": "B"]
        ))
    }

    @Test("command resolver falls back to adapter command and method args")
    func commandResolverFallsBackToAdapterCommand() {
        let method = authMethod(
            args: ["auth", "login"],
            env: ["TOKEN": "1"],
            terminalAuth: nil
        )

        let command = ACPAuthTerminalCommand.resolve(method: method, fallbackCommand: "agent")

        #expect(command == ACPAuthTerminalCommand(
            command: "agent",
            args: ["auth", "login"],
            env: ["TOKEN": "1"]
        ))
    }

    @Test("command resolver ignores non-terminal auth methods")
    func commandResolverRequiresTerminalMethod() {
        let method = authMethod(kind: .envVar, args: ["auth", "login"])

        #expect(ACPAuthTerminalCommand.resolve(method: method, fallbackCommand: "agent") == nil)
    }

    private func authMethod(
        id: String = "login",
        name: String = "Sign in",
        kind: ACPInitializeResult.ACPAuthMethod.Kind = .terminal,
        args: [String]? = nil,
        env: [String: String]? = nil,
        terminalAuth: ACPInitializeResult.ACPAuthMethod.TerminalAuthMeta? = nil
    ) -> ACPInitializeResult.ACPAuthMethod {
        ACPInitializeResult.ACPAuthMethod(
            id: id,
            name: name,
            kind: kind,
            args: args,
            env: env,
            meta: terminalAuth.map {
                ACPInitializeResult.ACPAuthMethod.Meta(terminalAuth: $0)
            }
        )
    }
}
