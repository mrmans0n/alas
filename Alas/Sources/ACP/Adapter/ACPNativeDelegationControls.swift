import Foundation

/// How Alas turns off an adapter's own subagent tool. Each case names a
/// verified adapter contract; new adapters (OMP, OpenCode, …) add a case here
/// and a branch in `ACPNativeDelegationSupport.resolve` and the launch hooks.
enum ACPNativeDelegationMechanism: Equatable, Sendable {
    /// `claude-agent-acp`: `_meta.claudeCode.options.disallowedTools` on every
    /// session/new, session/load, session/resume, and session/fork.
    case claudeDisallowedTools
    /// `codex-acp`: `CODEX_CONFIG` process env, merged into the Codex config
    /// of every thread the adapter starts or resumes.
    case codexConfigEnvironment
    /// `opencode acp`: `OPENCODE_CONFIG_CONTENT` process env denying the
    /// `task` permission, checked against every agent's effective ruleset
    /// (`opencode agent list`) before each launch.
    case openCodeConfigContent
    /// `omp acp`: a launch-only `--config` overlay setting
    /// `task.maxRecursionDepth` to 0. OMP deep merges it over the user's
    /// global and project settings, which removes the `task` and `hub` tools
    /// and makes eval's `agent()`/`workpool()` fail their spawn preflight.
    case ompConfigOverlay
    /// `pi-acp`: `PI_ACP_PI_COMMAND` pointing at an Alas-owned wrapper that
    /// runs `pi` with `--exclude-tools` for every tool of the known Pi
    /// subagent extensions (`ACPPiSubagentExtensions`).
    case piCommandWrapper

    /// The `agentInfo.name` of the adapter whose contract was verified. A
    /// different ACP server that happens to share the binary name (Alas
    /// accepts any same-named executable on PATH) is not trusted.
    var verifiedAdapterName: String {
        switch self {
        case .claudeDisallowedTools: ACPManagedAdapterDescriptor.claude.packageName
        case .codexConfigEnvironment: ACPManagedAdapterDescriptor.codex.packageName
        case .openCodeConfigContent: ACPOpenCodeTaskPolicy.adapterName
        case .ompConfigOverlay: "oh-my-pi"
        case .piCommandWrapper: ACPManagedAdapterDescriptor.pi.packageName
        }
    }

    /// Lowest adapter version whose model-facing request was verified to
    /// omit the native tool. Older or unidentified adapters fail the launch
    /// instead of running as if enforced.
    var minimumAdapterVersion: String {
        switch self {
        case .claudeDisallowedTools: "0.81.2"
        case .codexConfigEnvironment: "1.13.1"
        case .openCodeConfigContent: "1.18.33"
        case .ompConfigOverlay: "18.2.11"
        case .piCommandWrapper: "0.0.34"
        }
    }

    /// First major version whose native-tool control has not been verified.
    /// OpenCode 2 removed `opencode agent list` and renamed `task` to
    /// `subagent`, so the 1.x check cannot vouch for it.
    var firstUnverifiedMajorVersion: Int? {
        switch self {
        case .openCodeConfigContent: 2
        case .claudeDisallowedTools, .codexConfigEnvironment, .ompConfigOverlay, .piCommandWrapper: nil
        }
    }
}

/// What turning on "Disable native subagents" can actually do for an agent.
/// Derived from verified adapter behavior only — never from the ACP
/// `subagents` capability, which controls rendering, not what the model can
/// call.
enum ACPNativeDelegationSupport: Equatable, Sendable {
    /// The native tool is removed from the model's tool list.
    case toolOmission(ACPNativeDelegationMechanism)
    /// The native tool stays visible but its calls are rejected.
    case runtimeDenial(ACPNativeDelegationMechanism)
    /// The agent has native subagents, but no control is verified yet.
    case unverified
    /// Custom or unknown agents.
    case unsupported

    static func resolve(agentID: String) -> ACPNativeDelegationSupport {
        switch agentID {
        case ACPManagedAdapterDescriptor.claude.agentID: .toolOmission(.claudeDisallowedTools)
        case ACPManagedAdapterDescriptor.codex.agentID: .toolOmission(.codexConfigEnvironment)
        case ACPOpenCodeTaskPolicy.agentID: .toolOmission(.openCodeConfigContent)
        case ACPManagedAdapterDescriptor.pi.agentID: .toolOmission(.piCommandWrapper)
        case "omp": .toolOmission(.ompConfigOverlay)
        case "cursor-agent", "gemini", "antigravity", "copilot": .unverified
        default: .unsupported
        }
    }

    var mechanism: ACPNativeDelegationMechanism? {
        switch self {
        case .toolOmission(let mechanism), .runtimeDenial(let mechanism): mechanism
        case .unverified, .unsupported: nil
        }
    }

    var canEnforce: Bool { mechanism != nil }

    /// Settings copy for this agent's current support. Enforced states say
    /// exactly which tool is affected; nothing else claims enforcement.
    var settingsDescription: String {
        switch self {
        case .toolOmission(.claudeDisallowedTools):
            return "Removes Claude's Agent/Task and Workflow tools, and the "
                + "SendMessage and ListAgents tools that reach other Claude Code "
                + "sessions on the same host, from the model's tool list. TaskStop is "
                + "not affected. Delegated Claude sessions never get SendMessage "
                + "or ListAgents, whether or not this is on; they report through "
                + "Alas instead."
        case .toolOmission(.codexConfigEnvironment):
            return "Turns off Codex multi-agent tools (spawn_agent and related) "
                + "through CODEX_CONFIG, keeping any CODEX_CONFIG you already set. "
                + "Local sessions only."
        case .toolOmission(.openCodeConfigContent):
            return "Removes OpenCode's task tool from every agent through "
                + "OPENCODE_CONFIG_CONTENT, keeping any OPENCODE_CONFIG_CONTENT you "
                + "already set. Before each launch Alas checks every OpenCode agent's "
                + "effective permissions; if managed or other configuration keeps "
                + "task enabled, the session fails to start instead. OpenCode 1.x, "
                + "local sessions only."
        case .toolOmission(.ompConfigOverlay):
            return "Starts OMP with a launch-only settings overlay that sets "
                + "task.maxRecursionDepth to 0. This removes the task and hub tools "
                + "and makes eval's agent() and workpool() fail; eval otherwise "
                + "works. Your ~/.omp and project settings are not changed. "
                + "Local sessions only."
        case .toolOmission(.piCommandWrapper):
            return "Pi has no built-in subagent tool. This removes the subagent tools of "
                + "known Pi extensions (" + Self.piCoveredToolsDescription + ") from the "
                + "model's tool list, by starting Pi through an Alas wrapper that adds "
                + "--exclude-tools. Tools from other extensions are not affected. Your Pi "
                + "settings and any PI_ACP_PI_COMMAND you set are kept. Local sessions only."
        case .runtimeDenial:
            return "The native subagent tool stays visible to the model, but "
                + "its calls are rejected."
        case .unverified:
            return "Alas has not verified a way to turn off this agent's native "
                + "subagents, so this option is unavailable."
        case .unsupported:
            return "Not available for custom agents."
        }
    }

    static let activationDescription = "Applies to sessions created after you "
        + "change it; existing sessions keep the setting they started with, and "
        + "subagents already running are not stopped. This is not a sandbox: "
        + "shell commands and extensions can still start other agents."

    /// `subagent, bg_wait, and subagent_supervisor (pi-subagents)`.
    static var piCoveredToolsDescription: String {
        ACPPiSubagentExtensions.known.map { ext in
            var tools = ext.delegationTools
            let last = tools.removeLast()
            let list = tools.isEmpty ? last : tools.joined(separator: ", ") + ", and " + last
            return "\(list) from \(ext.packageName)"
        }.joined(separator: "; ")
    }

    /// Full settings-row copy: what the control does (or why it is
    /// unavailable), what the installed extensions leave uncovered (Pi),
    /// when it takes effect, and whether Alas delegation is left as the
    /// alternative.
    func settingsRowDescription(
        isOn: Bool,
        alasToolsExposed: Bool,
        extensionCoverage: ACPPiSubagentExtensions.Coverage? = nil
    ) -> String {
        guard canEnforce else { return settingsDescription }
        var text = settingsDescription
        if mechanism == .piCommandWrapper, let extensionCoverage {
            text += " " + extensionCoverage.settingsDescription
        }
        text += " " + Self.activationDescription
        if isOn {
            text += alasToolsExposed
                ? " Sessions are told to delegate through Alas child sessions instead."
                : " Alas tools are turned off (Expose Alas tools to agents), so these "
                    + "sessions cannot delegate at all."
        }
        return text
    }
}

enum ACPNativeDelegationError: LocalizedError, Equatable {
    case malformedCodexConfig(String)
    case malformedOpenCodeConfig(String)
    case openCodeTaskStillEnabled(agents: [String])
    case openCodePolicyUnverifiable(String)
    case remoteHostUnsupported(agentID: String)
    case adapterVersionUnverified(agentID: String, found: String?, minimum: String)
    case adapterVersionUnsupported(agentID: String, found: String, firstUnverifiedMajor: Int)
    case adapterUnverified(agentID: String, found: String?, expected: String)
    case launchOverlayUnavailable(agentID: String, detail: String)
    case piCommandUnavailable(command: String, isUserCommand: Bool)

    var errorDescription: String? {
        switch self {
        case .malformedCodexConfig(let detail):
            return "Native subagents are disabled for this session, but the "
                + "CODEX_CONFIG environment variable cannot be merged: \(detail). "
                + "Fix CODEX_CONFIG or turn off \"Disable native subagents\" for "
                + "Codex in Settings → Agents, then start a new session."
        case .malformedOpenCodeConfig(let detail):
            return "Native subagents are disabled for this session, but the "
                + "OPENCODE_CONFIG_CONTENT environment variable cannot be merged: "
                + "\(detail). Fix OPENCODE_CONFIG_CONTENT or turn off \"Disable native "
                + "subagents\" for OpenCode in Settings → Agents, then start a new session."
        case .openCodeTaskStillEnabled(let agents):
            return "Native subagents are disabled for this session, but OpenCode "
                + "configuration keeps the task tool enabled for "
                + "\(agents.joined(separator: ", ")) even after Alas denies it. "
                + "Managed configuration (/Library/Application Support/opencode or an "
                + "MDM profile), OPENCODE_PERMISSION, a legacy \"mode\" entry, or a "
                + "permission block that lists \"*\" after \"task\" overrides Alas. "
                + "Remove that override or turn off \"Disable native subagents\" for "
                + "OpenCode in Settings → Agents, then start a new session."
        case .openCodePolicyUnverifiable(let detail):
            return "Native subagents are disabled for this session, but Alas could "
                + "not check OpenCode's effective permissions (opencode agent list "
                + "\(detail)). Fix the OpenCode installation or turn off \"Disable "
                + "native subagents\" for OpenCode in Settings → Agents, then start a "
                + "new session."
        case .remoteHostUnsupported(let agentID):
            return "Native subagents are disabled for this session, but Alas can "
                + "only enforce that for \(agentID) on this Mac. Turn off \"Disable "
                + "native subagents\" in Settings → Agents to use it on a remote "
                + "host, then start a new session."
        case .adapterVersionUnverified(let agentID, let found, let minimum):
            let version = found.map { "version \($0)" } ?? "an unidentified version"
            return "Native subagents are disabled for this session, but the "
                + "\(agentID) ACP adapter reported \(version); disabling them is "
                + "verified from \(minimum). Update the adapter or turn off "
                + "\"Disable native subagents\" in Settings → Agents, then start a "
                + "new session."
        case .adapterVersionUnsupported(let agentID, let found, let major):
            return "Native subagents are disabled for this session, but the "
                + "\(agentID) ACP adapter reported version \(found); Alas has not "
                + "verified how to disable them from version \(major) on. Turn off "
                + "\"Disable native subagents\" in Settings → Agents, then start a "
                + "new session."
        case .adapterUnverified(let agentID, let found, let expected):
            let name = found.map { "\"\($0)\"" } ?? "an unnamed adapter"
            return "Native subagents are disabled for this session, but the "
                + "\(agentID) ACP server identified itself as \(name); disabling "
                + "them is verified only for \(expected). Point Alas at that adapter "
                + "or turn off \"Disable native subagents\" in Settings → Agents, "
                + "then start a new session."
        case .launchOverlayUnavailable(let agentID, let detail):
            return "Native subagents are disabled for this session, but Alas could "
                + "not write the \(agentID) launch file: \(detail). Check "
                + "that Alas's Application Support folder is writable or turn off "
                + "\"Disable native subagents\" in Settings → Agents, then start a "
                + "new session."
        case .piCommandUnavailable(let command, let isUserCommand):
            let fix = isUserCommand
                ? "Fix PI_ACP_PI_COMMAND"
                : "Install Pi (npm install -g @earendil-works/pi-coding-agent)"
            return "Native subagents are disabled for this session, but Alas could "
                + "not find the Pi command \"\(command)\" that its launch wrapper runs. "
                + "\(fix) or turn off \"Disable native subagents\" for Pi in "
                + "Settings → Agents, then start a new session."
        }
    }
}

/// The launch/session hooks that apply a session's native-delegation policy.
/// All of them are no-ops when the policy is off or the agent has no
/// verified mechanism.
enum ACPNativeDelegationControls {
    /// Claude tools that start or orchestrate native subagents. Workflow
    /// runs scripted multi-agent jobs, so it is removed with Agent/Task.
    static let claudeNativeSubagentTools = ["Agent", "Task", "Workflow"]
    /// Claude tools that reach other Claude Code sessions on the same host,
    /// outside Alas's parent/child authorization. Delegated children always
    /// lose them, because they must report through Alas's `session_send`.
    static let claudeCrossSessionTools = ["SendMessage", "ListAgents"]
    static let codexConfigKey = "CODEX_CONFIG"
    /// The whole OMP overlay. It sets nothing else, so every other key keeps
    /// the value from the user's global and project settings.
    static let ompOverlayContents = "task:\n  maxRecursionDepth: 0\n"

    /// The `_meta` Alas sends on every session request. With the policy on,
    /// Claude loses its native subagent tools and its cross-session tools. A
    /// delegated child always loses the cross-session tools, whatever the
    /// policy, so it reports only through Alas.
    static func sessionMeta(
        agentID: String,
        nativeSubagentsDisabled: Bool,
        isDelegatedChild: Bool
    ) -> ACPSessionMeta? {
        guard ACPNativeDelegationSupport.resolve(agentID: agentID).mechanism == .claudeDisallowedTools
        else { return nil }
        let disallowed: [String]
        if nativeSubagentsDisabled {
            disallowed = claudeNativeSubagentTools + claudeCrossSessionTools
        } else if isDelegatedChild {
            disallowed = claudeCrossSessionTools
        } else {
            return nil
        }
        return ACPSessionMeta(claudeCode: .init(options: .init(disallowedTools: disallowed)))
    }

    /// Applies process-level controls to the launch spec. `inheritedEnvironment`
    /// is the environment the adapter process would otherwise inherit, so an
    /// existing `CODEX_CONFIG` is merged rather than replaced.
    static func applyingLaunchControls(
        to spec: ACPLaunchSpec,
        nativeSubagentsDisabled: Bool,
        inheritedEnvironment: [String: String],
        isRemote: Bool,
        overlayDirectory: URL = ACPLaunchOverlay.defaultDirectory
    ) throws -> ACPLaunchSpec {
        guard nativeSubagentsDisabled,
              let mechanism = ACPNativeDelegationSupport.resolve(agentID: spec.agentID).mechanism
        else { return spec }
        // Remote launches either drop extraEnv or cannot see the remote
        // user's CODEX_CONFIG, OPENCODE_CONFIG_CONTENT, PI_ACP_PI_COMMAND, or
        // a local overlay or wrapper file, so enforcement there would be
        // unverifiable.
        func requireLocal() throws {
            if isRemote { throw ACPNativeDelegationError.remoteHostUnsupported(agentID: spec.agentID) }
        }
        switch mechanism {
        case .claudeDisallowedTools:
            // Session-level control (`sessionMeta`); nothing to launch with.
            return spec
        case .codexConfigEnvironment:
            try requireLocal()
            let existing = spec.extraEnv[codexConfigKey] ?? inheritedEnvironment[codexConfigKey]
            return spec.mergingExtraEnv([codexConfigKey: try mergedCodexConfig(existing: existing)])
        case .openCodeConfigContent:
            try requireLocal()
            let key = ACPOpenCodeTaskPolicy.configKey
            let existing = spec.extraEnv[key] ?? inheritedEnvironment[key]
            return spec.mergingExtraEnv([key: try ACPOpenCodeTaskPolicy.mergedConfig(existing: existing)])
        case .ompConfigOverlay:
            try requireLocal()
            let overlay: URL
            do {
                overlay = try ACPLaunchOverlay.ensure(
                    ompOverlayContents, named: "omp-native-subagents-off.yml", in: overlayDirectory)
            } catch {
                throw ACPNativeDelegationError.launchOverlayUnavailable(
                    agentID: spec.agentID, detail: error.localizedDescription)
            }
            // Appended last: OMP applies `--config` files in order, so this
            // one wins over any overlay passed earlier on the command line.
            return spec.appendingArguments(["--config", overlay.path])
        case .piCommandWrapper:
            try requireLocal()
            let wrapper: URL
            do {
                wrapper = try ACPLaunchOverlay.ensure(
                    ACPPiSubagentExtensions.wrapperContents,
                    named: ACPPiSubagentExtensions.wrapperFileName,
                    in: overlayDirectory,
                    permissions: 0o700
                )
            } catch {
                throw ACPNativeDelegationError.launchOverlayUnavailable(
                    agentID: spec.agentID, detail: error.localizedDescription)
            }
            return spec.mergingExtraEnv(try ACPPiSubagentExtensions.launchEnvironment(
                extraEnv: spec.extraEnv,
                inheritedEnvironment: inheritedEnvironment,
                wrapper: wrapper
            ))
        }
    }

    /// Fails unless the adapter identifies itself as the verified package at
    /// a verified version.
    static func verifyAdapter(
        agentID: String,
        nativeSubagentsDisabled: Bool,
        agentInfo: ACPImplementationInfo?
    ) throws {
        guard nativeSubagentsDisabled,
              let mechanism = ACPNativeDelegationSupport.resolve(agentID: agentID).mechanism
        else { return }
        guard agentInfo?.name == mechanism.verifiedAdapterName else {
            throw ACPNativeDelegationError.adapterUnverified(
                agentID: agentID,
                found: agentInfo?.name,
                expected: mechanism.verifiedAdapterName
            )
        }
        try checkAdapterVersion(agentInfo?.version, mechanism: mechanism, agentID: agentID)
    }

    /// Fails unless `version` is within the verified range of `mechanism`:
    /// at least its minimum and below its first unverified major. A
    /// pre-release of an unverified major counts as that major.
    static func checkAdapterVersion(
        _ version: String?,
        mechanism: ACPNativeDelegationMechanism,
        agentID: String
    ) throws {
        guard let version, isVersion(version, atLeast: mechanism.minimumAdapterVersion) else {
            throw ACPNativeDelegationError.adapterVersionUnverified(
                agentID: agentID, found: version, minimum: mechanism.minimumAdapterVersion)
        }
        if let ceiling = mechanism.firstUnverifiedMajorVersion,
           let major = version.split(separator: ".").first.flatMap({ Int($0) }),
           major >= ceiling {
            throw ACPNativeDelegationError.adapterVersionUnsupported(
                agentID: agentID, found: version, firstUnverifiedMajor: ceiling)
        }
    }

    /// `existing` merged with the keys that turn Codex multi-agent tools off.
    /// Unrelated keys are kept; the three enforcement keys always end up
    /// `false`, which is the strictest value they can take.
    static func mergedCodexConfig(existing: String?) throws -> String {
        var root: [String: Any] = [:]
        if let existing, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parsed: Any
            do {
                parsed = try JSONSerialization.jsonObject(with: Data(existing.utf8))
            } catch {
                throw ACPNativeDelegationError.malformedCodexConfig("it is not valid JSON")
            }
            guard let object = parsed as? [String: Any] else {
                throw ACPNativeDelegationError.malformedCodexConfig("it must be a JSON object")
            }
            root = object
        }
        // Codex also accepts dotted keys (`"agents.enabled": true`). One that
        // overlaps an enforcement path would race the nested value below, so
        // refuse it instead of guessing which one Codex applies.
        let enforcedPaths = ["agents.enabled", "features.multi_agent", "features.multi_agent_v2.enabled"]
        for key in root.keys where key.contains(".") {
            let overlaps = enforcedPaths.contains { path in
                path == key || path.hasPrefix(key + ".") || key.hasPrefix(path + ".")
            }
            if overlaps {
                throw ACPNativeDelegationError.malformedCodexConfig(
                    "the dotted key \"\(key)\" overlaps a setting Alas must control; use nested objects instead"
                )
            }
        }

        var agents = try object(root["agents"], key: "agents")
        agents["enabled"] = false
        root["agents"] = agents

        var features = try object(root["features"], key: "features")
        features["multi_agent"] = false
        // `multi_agent_v2` may be a plain feature flag or a table; either
        // way the table form below disables it.
        var multiAgentV2 = features["multi_agent_v2"] as? [String: Any] ?? [:]
        multiAgentV2["enabled"] = false
        features["multi_agent_v2"] = multiAgentV2
        root["features"] = features

        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private static func object(_ value: Any?, key: String) throws -> [String: Any] {
        guard let value else { return [:] }
        guard let object = value as? [String: Any] else {
            throw ACPNativeDelegationError.malformedCodexConfig("\"\(key)\" must be an object")
        }
        return object
    }

    /// Numeric dotted-version compare; a prerelease suffix (`1.2.3-beta`)
    /// counts as below its release.
    static func isVersion(_ version: String, atLeast minimum: String) -> Bool {
        let (core, isPrerelease) = {
            let parts = version.split(separator: "-", maxSplits: 1)
            return (parts.first.map(String.init) ?? "", parts.count > 1)
        }()
        let lhs = core.split(separator: ".").map { Int($0) }
        let rhs = minimum.split(separator: ".").compactMap { Int($0) }
        guard !lhs.isEmpty, lhs.allSatisfy({ $0 != nil }) else { return false }
        let values = lhs.compactMap { $0 }
        for index in 0..<max(values.count, rhs.count) {
            let l = index < values.count ? values[index] : 0
            let r = index < rhs.count ? rhs[index] : 0
            if l != r { return l > r }
        }
        return !isPrerelease
    }
}

/// Alas-owned files passed to adapters on their command line (OMP settings
/// overlays) or through their environment (the Pi launch wrapper).
///
/// An OMP process re-reads its `--config` files after startup (eval's
/// `agent()` loads settings again, and fails with "Config overlay not found"
/// if the file is gone), so an overlay must outlive every process launched
/// with it, including processes a broker keeps running across Alas restarts.
/// The same holds for the Pi wrapper: `pi-acp` runs it again for every new or
/// loaded session. Each file is therefore one fixed file per policy, rewritten atomically
/// before every launch that uses it and never deleted while Alas runs. Its
/// contents are fixed and hold no user data.
enum ACPLaunchOverlay {
    static var defaultDirectory: URL {
        Paths.appSupportRoot.appendingPathComponent("acp-launch-overlays", isDirectory: true)
    }

    /// Makes `directory/name` hold exactly `contents` (owner-only;
    /// `permissions` 0o700 for an executable) and returns its URL. A reader
    /// never sees a partial file.
    static func ensure(
        _ contents: String,
        named name: String,
        in directory: URL,
        permissions: Int = 0o600
    ) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let url = directory.appendingPathComponent(name)
        let data = Data(contents.utf8)
        let staging = directory.appendingPathComponent(".\(name).\(UUID().uuidString)")
        guard fileManager.createFile(atPath: staging.path, contents: data, attributes: [.posixPermissions: permissions]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        guard rename(staging.path, url.path) == 0 else {
            let code = errno
            try? fileManager.removeItem(at: staging)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return url
    }
}
