import Foundation
import Testing
@testable import Alas

@Suite("ACPNativeDelegationControls")
struct ACPNativeDelegationControlsTests {
    @Test(
        "support resolves per agent and only verified controls can enforce",
        arguments: [
            ("claude", ACPNativeDelegationSupport.toolOmission(.claudeDisallowedTools)),
            ("codex", .toolOmission(.codexConfigEnvironment)),
            ("pi", .extensionDependent),
            ("cursor-agent", .unverified),
            ("gemini", .unverified),
            ("copilot", .unverified),
            ("opencode", .toolOmission(.openCodeConfigContent)),
            ("omp", .toolOmission(.ompConfigOverlay)),
            ("3F2504E0-4F89-11D3-9A0C-0305E82C3301", .unsupported),
        ]
    )
    func supportResolution(agentID: String, expected: ACPNativeDelegationSupport) {
        let support = ACPNativeDelegationSupport.resolve(agentID: agentID)
        #expect(support == expected)
        #expect(support.canEnforce == ["claude", "codex", "opencode", "omp"].contains(agentID))
        // Unenforceable states never carry the activation/enforcement copy.
        if !support.canEnforce {
            #expect(support.settingsRowDescription(isOn: true, alasToolsExposed: true)
                == support.settingsDescription)
        }
    }

    @Test("a stored preference is ignored for agents without a verified control")
    func preferenceIsClampedToEnforceableAgents() {
        var agents = AppConfig.defaults.agents
        for id in ["claude", "codex", "cursor-agent", "pi"] {
            agents.builtinState[id] = BuiltinAgentState(isEnabled: true, nativeSubagentsDisabled: true)
        }
        #expect(agents.nativeSubagentsDisabled(for: "claude"))
        #expect(agents.nativeSubagentsDisabled(for: "codex"))
        #expect(!agents.nativeSubagentsDisabled(for: "cursor-agent"))
        #expect(!agents.nativeSubagentsDisabled(for: "pi"))
        #expect(!AppConfig.defaults.agents.nativeSubagentsDisabled(for: "claude"))
    }

    @Test(
        "Claude disallowedTools follow the policy, and delegated children always lose cross-session tools",
        arguments: [
            (false, false, nil),
            (false, true, ["SendMessage", "ListAgents"]),
            (true, false, ["Agent", "Task", "Workflow", "SendMessage", "ListAgents"]),
            (true, true, ["Agent", "Task", "Workflow", "SendMessage", "ListAgents"]),
        ] as [(Bool, Bool, [String]?)]
    )
    func claudeSessionMeta(policyOn: Bool, isDelegatedChild: Bool, expected: [String]?) {
        let meta = ACPNativeDelegationControls.sessionMeta(
            agentID: "claude",
            nativeSubagentsDisabled: policyOn,
            isDelegatedChild: isDelegatedChild
        )
        #expect(meta?.claudeCode?.options.disallowedTools == expected)
        #expect(ACPNativeDelegationControls.sessionMeta(
            agentID: "codex",
            nativeSubagentsDisabled: policyOn,
            isDelegatedChild: isDelegatedChild
        ) == nil)
    }

    @Test("CODEX_CONFIG merge keeps unrelated keys and forces every enforcement key off")
    func codexConfigMergePreservesAndTightens() throws {
        let existing = """
        {"model":"o5","agents":{"enabled":true,"max_threads":3},
         "features":{"web_search":true,"multi_agent":true,"multi_agent_v2":true},
         "features.web_search_request":true}
        """
        let merged = try ACPNativeDelegationControls.mergedCodexConfig(existing: existing)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(merged.utf8)) as? [String: Any]
        )
        #expect(object["model"] as? String == "o5")
        #expect(object["features.web_search_request"] as? Bool == true)
        let agents = try #require(object["agents"] as? [String: Any])
        #expect(agents["enabled"] as? Bool == false)
        #expect(agents["max_threads"] as? Int == 3)
        let features = try #require(object["features"] as? [String: Any])
        #expect(features["web_search"] as? Bool == true)
        #expect(features["multi_agent"] as? Bool == false)
        #expect((features["multi_agent_v2"] as? [String: Any])?["enabled"] as? Bool == false)
    }

    @Test("an absent CODEX_CONFIG yields just the enforcement keys")
    func codexConfigFromNothing() throws {
        for existing in [nil, "", "  \n"] {
            #expect(try ACPNativeDelegationControls.mergedCodexConfig(existing: existing)
                == #"{"agents":{"enabled":false},"features":{"multi_agent":false,"multi_agent_v2":{"enabled":false}}}"#)
        }
    }

    @Test(
        "a CODEX_CONFIG Alas cannot merge safely fails instead of being replaced",
        arguments: [
            "not json",
            "[1, 2]",
            #"{"agents": true}"#,
            #"{"features": "all"}"#,
            #"{"agents.enabled": true}"#,
            #"{"features.multi_agent_v2": {"enabled": true}}"#,
        ]
    )
    func malformedCodexConfigFails(existing: String) {
        #expect(throws: ACPNativeDelegationError.self) {
            try ACPNativeDelegationControls.mergedCodexConfig(existing: existing)
        }
    }

    @Test("Codex launch controls merge the inherited CODEX_CONFIG and refuse remote hosts")
    func codexLaunchControls() throws {
        let codex = try #require(ACPLaunchCatalog.spec(for: "codex"))
        let inherited = ["CODEX_CONFIG": #"{"model":"o5"}"#]

        let local = try ACPNativeDelegationControls.applyingLaunchControls(
            to: codex, nativeSubagentsDisabled: true, inheritedEnvironment: inherited, isRemote: false)
        let config = try #require(local.extraEnv["CODEX_CONFIG"])
        #expect(config.contains(#""model":"o5""#))
        #expect(config.contains(#""agents":{"enabled":false}"#))

        let off = try ACPNativeDelegationControls.applyingLaunchControls(
            to: codex, nativeSubagentsDisabled: false, inheritedEnvironment: inherited, isRemote: false)
        #expect(off == codex)

        #expect(throws: ACPNativeDelegationError.remoteHostUnsupported(agentID: "codex")) {
            try ACPNativeDelegationControls.applyingLaunchControls(
                to: codex, nativeSubagentsDisabled: true, inheritedEnvironment: [:], isRemote: true)
        }
        let opencode = try #require(ACPLaunchCatalog.spec(for: "opencode"))
        let openCodeLocal = try ACPNativeDelegationControls.applyingLaunchControls(
            to: opencode, nativeSubagentsDisabled: true,
            inheritedEnvironment: ["OPENCODE_CONFIG_CONTENT": #"{"share":"disabled"}"#], isRemote: false)
        #expect(openCodeLocal.extraEnv["OPENCODE_CONFIG_CONTENT"]
            == #"{"share":"disabled","permission":{"task":"deny"}}"#)
        #expect(throws: ACPNativeDelegationError.remoteHostUnsupported(agentID: "opencode")) {
            try ACPNativeDelegationControls.applyingLaunchControls(
                to: opencode, nativeSubagentsDisabled: true, inheritedEnvironment: [:], isRemote: true)
        }
        let claude = try #require(ACPLaunchCatalog.spec(for: "claude"))
        #expect(try ACPNativeDelegationControls.applyingLaunchControls(
            to: claude, nativeSubagentsDisabled: true, inheritedEnvironment: inherited, isRemote: true) == claude)
    }

    @Test("OMP launches with an owner-only depth-0 overlay only when the policy is on and local")
    func ompLaunchOverlay() throws {
        let omp = try #require(ACPLaunchCatalog.spec(for: "omp"))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("omp-overlay-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func launch(disabled: Bool, remote: Bool) throws -> ACPLaunchSpec {
            try ACPNativeDelegationControls.applyingLaunchControls(
                to: omp, nativeSubagentsDisabled: disabled, inheritedEnvironment: [:],
                isRemote: remote, overlayDirectory: directory)
        }

        #expect(try launch(disabled: false, remote: false) == omp)
        #expect(throws: ACPNativeDelegationError.remoteHostUnsupported(agentID: "omp")) {
            try launch(disabled: true, remote: true)
        }

        // A tampered overlay from an earlier launch is replaced, not trusted.
        let overlay = directory.appendingPathComponent("omp-native-subagents-off.yml")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("task:\n  maxRecursionDepth: 2\n".utf8).write(to: overlay)
        let local = try launch(disabled: true, remote: false)
        #expect(local.arguments == ["acp", "--config", overlay.path])
        #expect(try String(contentsOf: overlay, encoding: .utf8) == "task:\n  maxRecursionDepth: 0\n")
        let permissions = try FileManager.default.attributesOfItem(atPath: overlay.path)[.posixPermissions]
        #expect(permissions as? Int == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [overlay.lastPathComponent])
    }

    @Test("an overlay Alas cannot write fails the OMP launch")
    func unwritableOverlayFailsLaunch() throws {
        let omp = try #require(ACPLaunchCatalog.spec(for: "omp"))
        // A regular file where the overlay directory should be.
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("omp-overlay-\(UUID().uuidString)")
        try Data().write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        #expect {
            try ACPNativeDelegationControls.applyingLaunchControls(
                to: omp, nativeSubagentsDisabled: true, inheritedEnvironment: [:],
                isRemote: false, overlayDirectory: blocker)
        } throws: { error in
            if case .launchOverlayUnavailable(agentID: "omp", _) = error as? ACPNativeDelegationError { true } else { false }
        }
    }

    @Test(
        "OPENCODE_CONFIG_CONTENT merge keeps key order and ends each permission block with a task deny",
        arguments: [
            (nil, [], #"{"permission":{"task":"deny"}}"#),
            (
                #"{"model":"a/b","permission":{"task":"allow","bash":{"git push":"allow","git *":"deny"},"*":"ask"}}"#,
                [],
                #"{"model":"a/b","permission":{"bash":{"git push":"allow","git *":"deny"},"*":"ask","task":"deny"}}"#
            ),
            (#"{"permission":"ask"}"#, [], #"{"permission":{"*":"ask","task":"deny"}}"#),
            (
                "{// JSONC\n \"share\": \"disabled\", /* note */ \"n\": 1.50, \"s\": \"a\\\"b/c\",}",
                [],
                #"{"share":"disabled","n":1.50,"s":"a\"b/c","permission":{"task":"deny"}}"#
            ),
            (
                #"{"agent":{"build":{"model":"x","permission":{"task":"allow","*":"allow"}}}}"#,
                ["build", "custom"],
                #"{"agent":{"build":{"model":"x","permission":{"*":"allow","task":"deny"}},"#
                    + #""custom":{"permission":{"task":"deny"}}},"permission":{"task":"deny"}}"#
            ),
        ] as [(String?, [String], String)]
    )
    func openCodeConfigMerge(existing: String?, denyingAgents: [String], expected: String) throws {
        #expect(try ACPOpenCodeTaskPolicy.mergedConfig(existing: existing, denyingAgents: denyingAgents) == expected)
    }

    @Test(
        "an OPENCODE_CONFIG_CONTENT Alas cannot merge safely fails instead of being replaced",
        arguments: ["not json", "[1]", #"{"a": }"#, #"{"share":"disabled"} /*"#, #"{"permission": 3}"#, #"{"agent": []}"#, #"{"agent": {"build": 1}}"#]
    )
    func malformedOpenCodeConfigFails(existing: String) {
        #expect(throws: ACPNativeDelegationError.self) {
            try ACPOpenCodeTaskPolicy.mergedConfig(existing: existing, denyingAgents: ["build"])
        }
    }

    @Test(
        "OpenCode drops task only when the last matching rule is a blanket deny",
        arguments: [
            ([("*", "*", "allow"), ("task", "*", "deny")], true),
            ([("*", "*", "deny")], true),
            ([("task", "*", "deny"), ("*", "*", "allow")], false),
            ([("task", "*", "deny"), ("task", "general", "allow")], false),
            ([("*", "*", "allow"), ("task", "general", "deny")], false),
            ([("t?sk", "*", "deny")], true),
            ([], false),
        ] as [([(String, String, String)], Bool)]
    )
    func openCodeTaskRemoval(rules: [(String, String, String)], removed: Bool) {
        let rules = rules.map { ACPOpenCodeTaskPolicy.Rule(permission: $0.0, pattern: $0.1, action: $0.2) }
        #expect(ACPOpenCodeTaskPolicy.removesTask(rules) == removed)
    }

    /// Shape of `opencode agent list` (1.18.33): a header per agent, then its
    /// rules as pretty-printed JSON whose first line is indented.
    private static func agentList(_ agents: [(String, String, [(String, String, String)])]) -> String {
        agents.map { name, mode, rules in
            let body = rules.map {
                "  {\n    \"permission\": \"\($0.0)\",\n    \"pattern\": \"\($0.1)\",\n    \"action\": \"\($0.2)\"\n  }"
            }.joined(separator: ",\n")
            return "\(name) (\(mode))\n  [\n\(body)\n]\n"
        }.joined()
    }

    @Test("OpenCode verification adds agent-specific denies, then fails if an agent still keeps task")
    func openCodeVerification() async throws {
        let open = [("*", "*", "allow")]
        let denied = [("*", "*", "allow"), ("task", "*", "deny")]
        let seen = Recorder()
        // An agent-specific allow the overlay can outrank.
        let forced = try await ACPOpenCodeTaskPolicy.verifiedConfig(
            startingFrom: #"{"permission":{"task":"deny"}}"#
        ) { content in
            await seen.append(content)
            let fixed = content.contains(#""my agent":{"permission":{"task":"deny"}}"#)
            return Self.agentList([("build", "primary", denied), ("my agent", "all", fixed ? denied : open)])
        }
        #expect(forced == #"{"permission":{"task":"deny"},"agent":{"my agent":{"permission":{"task":"deny"}}}}"#)
        #expect(await seen.values.count == 2)

        // Managed configuration (or anything merged after the overlay) wins.
        await #expect(throws: ACPNativeDelegationError.openCodeTaskStillEnabled(agents: ["plan"])) {
            try await ACPOpenCodeTaskPolicy.verifiedConfig(startingFrom: "{}") { _ in
                Self.agentList([("build", "primary", denied), ("plan", "primary", open)])
            }
        }

        for output in ["", "build (primary)\n  not json\n"] {
            await #expect(throws: ACPNativeDelegationError.self) {
                try await ACPOpenCodeTaskPolicy.verifiedConfig(startingFrom: "{}") { _ in output }
            }
        }
    }

    private actor Recorder {
        var values: [String] = []
        func append(_ value: String) { values.append(value) }
    }

    @Test(
        "enforcement requires an adapter at or above the verified version",
        arguments: [
            ("claude", "0.81.2", true),
            ("claude", "0.90.0", true),
            ("claude", "0.81.1", false),
            ("claude", "0.82.0-beta.1", true),
            ("claude", "0.81.2-beta.1", false),
            ("codex", "1.13.1", true),
            ("codex", "1.9.9", false),
            ("codex", "garbage", false),
            ("opencode", "1.18.33", true),
            ("opencode", "1.18.32", false),
            ("omp", "18.2.11", true),
            ("omp", "18.2.10", false),
        ]
    )
    func adapterVersionGate(agentID: String, version: String, passes: Bool) {
        let name = ACPNativeDelegationSupport.resolve(agentID: agentID).mechanism!.verifiedAdapterName
        let info = ACPImplementationInfo(name: name, version: version)
        let verify = {
            try ACPNativeDelegationControls.verifyAdapter(
                agentID: agentID, nativeSubagentsDisabled: true, agentInfo: info)
        }
        if passes {
            #expect(throws: Never.self, performing: verify)
        } else {
            #expect(throws: ACPNativeDelegationError.self, performing: verify)
        }
    }

    @Test("a same-named ACP server that is not the verified package is rejected")
    func foreignAdapterIsRejected() {
        #expect(throws: ACPNativeDelegationError.adapterUnverified(
            agentID: "claude",
            found: "some-fork-acp",
            expected: "@agentclientprotocol/claude-agent-acp"
        )) {
            try ACPNativeDelegationControls.verifyAdapter(
                agentID: "claude",
                nativeSubagentsDisabled: true,
                agentInfo: .init(name: "some-fork-acp", version: "9.9.9"))
        }
    }

    @Test("an adapter without agentInfo fails only when the policy is on")
    func missingAgentInfo() {
        #expect(throws: ACPNativeDelegationError.self) {
            try ACPNativeDelegationControls.verifyAdapter(
                agentID: "claude", nativeSubagentsDisabled: true, agentInfo: nil)
        }
        #expect(throws: Never.self) {
            try ACPNativeDelegationControls.verifyAdapter(
                agentID: "claude", nativeSubagentsDisabled: false, agentInfo: nil)
        }
    }
}
