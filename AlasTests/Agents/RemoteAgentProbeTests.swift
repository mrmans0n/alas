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
        #expect(command.contains("__ALAS_AGENT_PROBE_AVAILABLE__ "))
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

        let stdout = """
        0
        __ALAS_AGENT_PROBE_AVAILABLE__ 0
        __ALAS_AGENT_PROBE_AVAILABLE__ 1
        __ALAS_AGENT_PROBE_AVAILABLE__ 1
        __ALAS_AGENT_PROBE_AVAILABLE__ 99
        nope
        """

        #expect(RemoteAgentProbe.availableAgentIDs(stdout: stdout, agents: agents) == ["one", "two"])
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
