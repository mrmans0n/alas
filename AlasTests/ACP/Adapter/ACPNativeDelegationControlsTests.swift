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
            ("pi", .toolOmission(.piCommandWrapper)),
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
        #expect(support.canEnforce == ["claude", "codex", "opencode", "omp", "pi"].contains(agentID))
        // Unenforceable states never carry the activation/enforcement copy.
        if !support.canEnforce {
            #expect(support.settingsRowDescription(isOn: true, alasToolsExposed: true)
                == support.settingsDescription)
        }
    }

    @Test("a stored preference is ignored for agents without a verified control")
    func preferenceIsClampedToEnforceableAgents() {
        var agents = AppConfig.defaults.agents
        for id in ["claude", "codex", "cursor-agent"] {
            agents.builtinState[id] = BuiltinAgentState(isEnabled: true, nativeSubagentsDisabled: true)
        }
        #expect(agents.nativeSubagentsDisabled(for: "claude"))
        #expect(agents.nativeSubagentsDisabled(for: "codex"))
        #expect(!agents.nativeSubagentsDisabled(for: "cursor-agent"))
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

    /// A temporary directory holding an executable `name` that prints its
    /// arguments one per line.
    private static func fakeCommandDirectory(named name: String = "pi") throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-wrapper \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let command = directory.appendingPathComponent(name)
        try Data("#!/bin/sh\nprintf '%s\\n' \"$@\"\n".utf8).write(to: command)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
        return directory
    }

    @Test(
        "Pi launches through the owner-only wrapper, chaining to a PI_ACP_PI_COMMAND the user already set",
        arguments: [
            (nil, nil, "pi"),
            (nil, "/custom/pi", "/custom/pi"),
            ("/agent/pi", "/custom/pi", "/agent/pi"),
            ("", nil, "pi"),
            // A relaunch that carries Alas's own wrapper forward, or another
            // Alas profile's copy, must not loop.
            ("WRAPPER", nil, "pi"),
            (nil, "OTHER-PROFILE-WRAPPER", "pi"),
            ("other-profile.sh", nil, "pi"),
        ] as [(String?, String?, String)]
    )
    func piLaunchWrapper(agentValue: String?, inheritedValue: String?, expectedTarget: String) throws {
        let directory = try Self.fakeCommandDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let wrapper = directory.appendingPathComponent("pi-native-subagents-off.sh")
        func resolve(_ value: String?) -> String? {
            guard let value else { return nil }
            if value == "WRAPPER" { return wrapper.path }
            if value == "OTHER-PROFILE-WRAPPER" || value == "other-profile.sh" {
                // Another profile's wrapper, by path or as a bare name on PATH.
                let other = directory.appendingPathComponent("other-profile.sh")
                try? Data(ACPPiSubagentExtensions.wrapperContents.utf8).write(to: other)
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: other.path)
                return value == "other-profile.sh" ? value : other.path
            }
            // Every user command must exist for the launch to pass.
            if value.hasPrefix("/") {
                let command = directory.appendingPathComponent(String(value.dropFirst()).replacingOccurrences(of: "/", with: "-"))
                try? FileManager.default.copyItem(at: directory.appendingPathComponent("pi"), to: command)
                return command.path
            }
            return value
        }
        let pi = try #require(ACPLaunchCatalog.spec(for: "pi"))
        var extraEnv = ["PATH": directory.path]
        if let agent = resolve(agentValue) { extraEnv["PI_ACP_PI_COMMAND"] = agent }
        let spec = pi.mergingExtraEnv(extraEnv)
        let inherited = resolve(inheritedValue).map { ["PI_ACP_PI_COMMAND": $0] } ?? [:]

        let launch = try ACPNativeDelegationControls.applyingLaunchControls(
            to: spec, nativeSubagentsDisabled: true, inheritedEnvironment: inherited,
            isRemote: false, overlayDirectory: directory)
        #expect(launch.arguments == spec.arguments)
        #expect(launch.extraEnv["PI_ACP_PI_COMMAND"] == wrapper.path)
        #expect(launch.extraEnv["ALAS_PI_ACP_PI_TARGET"] == resolve(expectedTarget) ?? expectedTarget)
        #expect(try String(contentsOf: wrapper, encoding: .utf8) == ACPPiSubagentExtensions.wrapperContents)
        let permissions = try FileManager.default.attributesOfItem(atPath: wrapper.path)[.posixPermissions]
        #expect(permissions as? Int == 0o700)
    }

    @Test("the Pi wrapper runs its target with every original argument and the registry exclusions")
    func piWrapperForwardsArguments() async throws {
        let directory = try Self.fakeCommandDirectory(named: "my pi")
        defer { try? FileManager.default.removeItem(at: directory) }
        let wrapper = try ACPLaunchOverlay.ensure(
            ACPPiSubagentExtensions.wrapperContents, named: "wrapper.sh", in: directory, permissions: 0o700)
        let target = directory.appendingPathComponent("my pi").path
        let run = { (env: [String: String]) in
            try await Process.run(
                wrapper.path, args: ["--mode", "rpc", "--session", "/tmp/a b.jsonl"],
                env: env.merging(["PATH": "/usr/bin:/bin"]) { $1 }, timeout: 10)
        }
        let result = try await run(["ALAS_PI_ACP_PI_TARGET": target])
        #expect(result.exitCode == 0)
        #expect(result.stdout.split(separator: "\n") == [
            "--mode", "rpc", "--session", "/tmp/a b.jsonl",
            "--exclude-tools", "subagent,bg_wait,subagent_supervisor",
        ])
        let missing = try await run(["ALAS_PI_ACP_PI_TARGET": directory.appendingPathComponent("gone").path])
        #expect(missing.exitCode == 127)
        #expect(missing.stderr.contains("cannot run the Pi command"))
    }

    @Test("a Pi command that cannot be found, or a remote host, fails the launch")
    func piLaunchFailures() throws {
        let pi = try #require(ACPLaunchCatalog.spec(for: "pi"))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-wrapper-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func launch(_ spec: ACPLaunchSpec, inherited: [String: String] = [:], remote: Bool = false) throws {
            _ = try ACPNativeDelegationControls.applyingLaunchControls(
                to: spec, nativeSubagentsDisabled: true, inheritedEnvironment: inherited,
                isRemote: remote, overlayDirectory: directory)
        }
        #expect(throws: ACPNativeDelegationError.piCommandUnavailable(command: "/missing/pi", isUserCommand: true)) {
            try launch(pi, inherited: ["PI_ACP_PI_COMMAND": "/missing/pi"])
        }
        #expect(throws: ACPNativeDelegationError.piCommandUnavailable(command: "pi", isUserCommand: false)) {
            try launch(pi.mergingExtraEnv(["PATH": directory.path]))
        }
        #expect(throws: ACPNativeDelegationError.remoteHostUnsupported(agentID: "pi")) {
            try launch(pi, remote: true)
        }
        #expect(try ACPNativeDelegationControls.applyingLaunchControls(
            to: pi, nativeSubagentsDisabled: false, inheritedEnvironment: [:], isRemote: false,
            overlayDirectory: directory) == pi)
    }

    @Test(
        "Pi package sources classify against the subagent registry",
        arguments: [
            ("npm:pi-subagents", ACPPiSubagentExtensions.PackageClass.known("pi-subagents")),
            ("npm:pi-subagents@0.68.0", .known("pi-subagents")),
            ("git:github.com/nicobailon/pi-subagents@abc123", .known("pi-subagents")),
            ("https://github.com/NicoBailon/pi-subagents.git", .known("pi-subagents")),
            ("git@github.com:nicobailon/pi-subagents#main", .known("pi-subagents")),
            ("npm:pi-mcp-adapter", .safe),
            ("npm:@scope/pi-subagents@^1", .unrecognized("@scope/pi-subagents")),
            ("npm:pi-web-access", .unrecognized("pi-web-access")),
            ("git:github.com/someone/pi-subagents", .unrecognized("github.com/someone/pi-subagents")),
            ("./local/ext", .unrecognized("./local/ext")),
        ]
    )
    func piPackageClassification(source: String, expected: ACPPiSubagentExtensions.PackageClass) {
        #expect(ACPPiSubagentExtensions.classifyPackage(source) == expected)
        #expect(ACPPiSubagentExtensions.classifyPackage(["source": source, "extensions": ["-x.ts"]] as [String: Any]) == expected)
    }

    /// Writes `pi-subagents`'s `package.json` where Pi installs npm and git
    /// sources under `base`; a nil version writes one without `version`.
    private static func installPiSubagents(version: String?, in base: URL) throws {
        let json = version.map { #"{"name":"pi-subagents","version":"\#($0)"}"# } ?? #"{"name":"pi-subagents"}"#
        for folder in ["npm/node_modules/pi-subagents", "git/github.com/nicobailon/pi-subagents"] {
            let root = base.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data(json.utf8).write(to: root.appendingPathComponent("package.json"))
        }
    }

    @Test(
        "only a verified pi-subagents version counts as covered",
        arguments: [
            ("npm:pi-subagents", "0.68.0", nil),
            ("npm:pi-subagents@0.68.4", "0.68.4", nil),
            ("git:github.com/nicobailon/pi-subagents@v0.68.2", "0.68.2", nil),
            ("npm:pi-subagents", "0.69.0", "pi-subagents 0.69.0 not verified"),
            ("npm:pi-subagents", "0.67.9", "pi-subagents 0.67.9 not verified"),
            ("npm:pi-subagents", "0.68.0-beta.1", "pi-subagents 0.68.0-beta.1 not verified"),
            ("npm:pi-subagents", "0.69.0-beta.1", "pi-subagents 0.69.0-beta.1 not verified"),
            ("npm:pi-subagents", nil, "pi-subagents (unreadable version) not verified"),
        ] as [(String, String?, String?)]
    )
    func piSubagentsVersionCoverage(source: String, version: String?, notVerified: String?) throws {
        let agentDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-version-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: agentDir) }
        try Self.installPiSubagents(version: version, in: agentDir)
        try Data(#"{"packages":["\#(source)"]}"#.utf8).write(to: agentDir.appendingPathComponent("settings.json"))
        let coverage = ACPPiSubagentExtensions.coverage(agentDirectory: agentDir)
        if let notVerified {
            #expect(coverage == .unrecognized(covered: [], unrecognized: [notVerified]))
        } else {
            #expect(coverage == .enforced(covered: ["pi-subagents"]))
        }
    }

    @Test(
        "Pi extension inventory reports coverage from global and project settings and folders",
        arguments: [
            (nil, [], nil, [], ACPPiSubagentExtensions.Coverage.nothingToDisable),
            (#"{"packages":["npm:pi-mcp-adapter"],"extensions":null}"#, ["alas-notify.ts"], nil, [], .nothingToDisable),
            // A user's own file with the hook's name is not Alas's hook.
            (nil, ["alas-notify.ts"], nil, ["alas-notify.ts"], .unrecognized(covered: [], unrecognized: ["alas-notify.ts (project demo)"])),
            (
                #"{"packages":["npm:pi-subagents",{"source":"npm:pi-mcp-adapter"}]}"#, [], nil, [],
                .enforced(covered: ["pi-subagents"])
            ),
            (
                #"{"packages":["npm:pi-subagents","npm:pi-web-access"],"extensions":["tools/x.ts","*.ts"]}"#,
                ["mine.ts", "notes.md", ".hidden.ts", "helper"], nil, [],
                .unrecognized(covered: ["pi-subagents"], unrecognized: ["pi-web-access", "x.ts", "helper", "mine.ts"])
            ),
            // Extensions the settings disable are not reported.
            (
                #"{"extensions":["-extensions/off.ts","!old-*","+extensions/old-kept.ts","tools/y.ts","-tools/y.ts"]}"#,
                ["off.ts", "old-a.ts", "old-kept.ts"], nil, [],
                .unrecognized(covered: [], unrecognized: ["old-kept.ts"])
            ),
            (
                nil, [], #"{"packages":["npm:pi-subagents","npm:other"]}"#, ["team.ts"],
                .unrecognized(covered: ["pi-subagents"], unrecognized: ["other (project demo)", "team.ts (project demo)"])
            ),
            ("not json", [], nil, [], .unrecognized(covered: [], unrecognized: ["unreadable GLOBAL"])),
        ] as [(String?, [String], String?, [String], ACPPiSubagentExtensions.Coverage)]
    )
    func piExtensionCoverage(
        globalSettings: String?,
        globalExtensions: [String],
        projectSettings: String?,
        projectExtensions: [String],
        expected: ACPPiSubagentExtensions.Coverage
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-inventory-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let agentDir = root.appendingPathComponent("agent", isDirectory: true)
        let project = root.appendingPathComponent("repo", isDirectory: true)
        func populate(_ base: URL, settings: String?, extensions: [String]) throws {
            let folder = base.appendingPathComponent("extensions", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if let settings {
                try Data(settings.utf8).write(to: base.appendingPathComponent("settings.json"))
            }
            try Self.installPiSubagents(version: "0.68.0", in: base)
            for name in extensions {
                let url = folder.appendingPathComponent(name)
                if name == "alas-notify.ts", base == agentDir {
                    try Data("// alas-managed-pi-hook-v3\n".utf8).write(to: url)
                } else if name.contains(".") {
                    try Data().write(to: url)
                } else {
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                }
            }
        }
        try populate(agentDir, settings: globalSettings, extensions: globalExtensions)
        try populate(project.appendingPathComponent(".pi", isDirectory: true),
                     settings: projectSettings, extensions: projectExtensions)
        let before = try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted()

        var coverage = ACPPiSubagentExtensions.coverage(agentDirectory: agentDir, projects: [("demo", project)])
        if case .unrecognized(let covered, let names) = coverage {
            let settingsPath = agentDir.appendingPathComponent("settings.json").path
            coverage = .unrecognized(covered: covered, unrecognized: names.map {
                $0.replacingOccurrences(of: settingsPath, with: "GLOBAL")
            })
        }
        #expect(coverage == expected)
        // A custom PI_ACP_PI_COMMAND can pass a later --exclude-tools, so it is never covered.
        let custom = ACPPiSubagentExtensions.coverage(
            agentDirectory: agentDir, projects: [("demo", project)], customPiCommand: "/opt/my-pi")
        guard case .unrecognized(_, let names) = custom else {
            Issue.record("a custom PI_ACP_PI_COMMAND must not count as enforced")
            return
        }
        #expect(names.last == "PI_ACP_PI_COMMAND /opt/my-pi")
        // Detection only reads.
        #expect(try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted() == before)
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

    @Test(
        "OpenCode --version output resolves to the version Alas gates on",
        arguments: [
            ("1.18.34\n", "1.18.34"),
            ("opencode v2.0.22\n", "2.0.22"),
            ("opencode v2.0.0-beta.3", "2.0.0-beta.3"),
            ("", nil),
            ("Usage: opencode [command]", nil),
        ] as [(String, String?)]
    )
    func openCodeReportedVersion(output: String, expected: String?) {
        #expect(ACPOpenCodeTaskPolicy.reportedVersion(output) == expected)
    }

    @Test("OpenCode 2 fails the native-subagent check with an OpenCode 2 message")
    func openCodeTwoIsUnsupported() {
        #expect(throws: ACPNativeDelegationError.adapterVersionUnsupported(
            agentID: "opencode", found: "2.0.22", firstUnverifiedMajor: 2
        )) {
            try ACPNativeDelegationControls.checkAdapterVersion(
                "2.0.22", mechanism: .openCodeConfigContent, agentID: "opencode")
        }
        #expect(throws: ACPNativeDelegationError.adapterVersionUnverified(
            agentID: "opencode", found: nil, minimum: "1.18.33"
        )) {
            try ACPNativeDelegationControls.checkAdapterVersion(
                nil, mechanism: .openCodeConfigContent, agentID: "opencode")
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
            ("opencode", "1.99.0", true),
            ("opencode", "2.0.22", false),
            ("opencode", "2.0.0-beta.3", false),
            ("omp", "18.2.11", true),
            ("omp", "18.2.10", false),
            ("pi", "0.0.34", true),
            ("pi", "0.0.33", false),
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
