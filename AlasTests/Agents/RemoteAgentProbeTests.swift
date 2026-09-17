import Testing
@testable import Alas

struct RemoteAgentProbeTests {
    @Test func commandChecksEachExecutableWithoutEmbeddingAgentIDs() {
        let agents = [
            TestAgents.custom(id: "bare-id", binary: "claude"),
            TestAgents.custom(id: "absolute-id", binary: "/opt/tools/codex"),
            TestAgents.custom(id: "home-id", binary: "~/bin/pi"),
            TestAgents.custom(id: "relative-id", binary: "tools/agent"),
            TestAgents.custom(id: "hostile-'-$()-id", binary: "bad'; touch /tmp/nope; '")
        ]

        let command = RemoteAgentProbe.command(agents: agents, workingDirectory: "/srv/repo with space")

        #expect(command.contains("command -v 'claude'"))
        #expect(command.contains("'/opt/tools/codex'"))
        #expect(command.contains("$HOME/"))
        #expect(command.contains("cd '/srv/repo with space'"))
        #expect(command.contains("; fi\nif "))
        #expect(!command.contains("; fi if "))
        #expect(!command.contains("hostile-'-$()-id"))
        #expect(!command.contains("touch /tmp/nope;  &&"))
    }

    @Test func parserMapsOnlyValidIndexesBackToIDs() {
        let agents = [
            TestAgents.custom(id: "one", binary: "one"),
            TestAgents.custom(id: "two", binary: "two")
        ]

        #expect(RemoteAgentProbe.availableAgentIDs(stdout: "0\n1\n1\n99\nnope\n", agents: agents) == ["one", "two"])
    }
}

private enum TestAgents {
    static func custom(id: String, binary: String) -> AgentDefinition {
        AgentDefinition(
            id: id,
            displayName: id,
            binary: binary,
            binaryOverride: nil,
            promptModeArgs: [],
            bypassPermissionsFlag: nil,
            extraTerminalArgs: nil,
            isBuiltin: false,
            isEnabled: true,
            builtinLogoAssetName: nil
        )
    }
}
