import CryptoKit
import Foundation
import AlasACP
import AlasModel
import AlasPlatform

extension ACPV2PreviewEligibility {
    public enum IdentityError: Error, Equatable, Sendable {
        case unsupportedCommand, unownedExecutable, invalidPackage, unaccountedEnvironment, missingInterpreter, configurationUnavailable, changedDuringResolution
    }

    /// Reads files off the main actor. No candidate code executes until its content
    /// matches an existing qualified record, including the helper and interpreter.
    public static func resolveIdentity(launchSpec: ACPLaunchSpec, helperURL: URL,
        environment: [String: String]? = nil, cwd: URL? = nil) async throws -> ACPV2PreviewLaunchIdentity {
        let environment = environment ?? ACPProcessEnvironment.sanitizedForACP(extra: launchSpec.extraEnv)
        let before = try await resolveFiles(launchSpec: launchSpec, helper: helperURL, environment: environment, cwd: cwd)
        guard qualifiedAdapters.contains(where: { contentMatches(before, $0) && $0.approvalMode == before.approvalMode && $0.providerID == before.providerID }) else { return before }
        let provider = await authenticatedProvider(before, environment: environment, cwd: cwd)
        try Task.checkCancellation()
        let after = try await resolveFiles(launchSpec: launchSpec, helper: helperURL, environment: environment, cwd: cwd)
        guard before == after else { throw IdentityError.changedDuringResolution }
        return after.replacingProvider(provider)
    }

    private static func resolveFiles(launchSpec: ACPLaunchSpec, helper: URL,
        environment: [String: String], cwd: URL?) async throws -> ACPV2PreviewLaunchIdentity {
        let worker = Task.detached(priority: .utility) {
            try fileIdentity(launchSpec: launchSpec, helper: helper, environment: environment, cwd: cwd)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    private static let injectedExecutionKeys: Set<String> = [
        "NODE_OPTIONS", "NODE_PATH", "BUN_OPTIONS", "LD_PRELOAD", "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH",
        "CODEX_PATH", "CLAUDE_CODE_EXECUTABLE", "CLAUDE_AGENT_SDK_CLI_PATH",
    ]
    private static let alternateProviderKeys: Set<String> = [
        "OPENAI_API_KEY", "OPENAI_BASE_URL", "CHATGPT_BASE_URL", "CODEX_CONFIG", "DEFAULT_AUTH_REQUEST",
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_MODEL_CONFIG",
        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY", "CLAUDE_CODE_OAUTH_TOKEN",
    ]

    private static func fileIdentity(launchSpec: ACPLaunchSpec, helper: URL,
        environment: [String: String], cwd: URL?) throws -> ACPV2PreviewLaunchIdentity {
        guard launchSpec.command.hasPrefix("/"), launchSpec.arguments.isEmpty, launchSpec.remoteNodeBinDirectory == nil,
              let descriptor = ACPManagedAdapterDescriptor.descriptor(for: launchSpec.agentID),
              descriptor.agentID == "claude" || descriptor.agentID == "codex",
              launchSpec.npmPackageName == descriptor.packageName else { throw IdentityError.unsupportedCommand }
        guard !injectedExecutionKeys.contains(where: { !(environment[$0] ?? "").isEmpty }) else { throw IdentityError.unaccountedEnvironment }
        let executable = URL(fileURLWithPath: launchSpec.command).resolvingSymlinksInPath().standardizedFileURL
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw IdentityError.unownedExecutable }
        let (root, manifest) = try packageContaining(executable, named: descriptor.packageName)
        guard let version = manifest["version"] as? String, let bin = manifest["bin"] as? [String: String],
              let relative = bin[descriptor.binaryName], !relative.hasPrefix("/"),
              root.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL.path == executable.path,
              executable.path.hasPrefix(root.path + "/"),
              let downstream = manifest["alasDownstream"] as? [String: String], let source = downstream["sourceCommit"] else { throw IdentityError.unownedExecutable }
        let entry = try FileHandle(forReadingFrom: executable)
        defer { try? entry.close() }
        let prefix = try entry.read(upToCount: 128) ?? Data()
        guard String(decoding: prefix, as: UTF8.self).split(separator: "\n").first == "#!/usr/bin/env node" else { throw IdentityError.unownedExecutable }
        let paths = (environment["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: false)
        guard !paths.isEmpty, paths.allSatisfy({ $0.hasPrefix("/") }) else { throw IdentityError.unaccountedEnvironment }
        guard let candidate = paths.map({ URL(fileURLWithPath: String($0)).appendingPathComponent("node") })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { throw IdentityError.missingInterpreter }
        let node = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard helper.isFileURL, helper.path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: helper.path) else { throw IdentityError.unownedExecutable }
        let routing = try routingConfiguration(environment: environment, cwd: cwd, agent: descriptor.agentID)
        let mode = descriptor.agentID == "codex" ? environment["INITIAL_AGENT_MODE"] ?? "unqualified" : routing.mode ?? "default"
        return .init(agentID: descriptor.agentID, packageName: descriptor.packageName, packageVersion: version,
            packageDigest: try ACPLaunchContentIdentity.packageDigest(at: root),
            helperDigest: try ACPLaunchContentIdentity.fileDigest(helper.resolvingSymlinksInPath()),
            providerID: routing.allowed ? (descriptor.agentID == "codex" ? "openai-chatgpt" : "anthropic-claude-ai") : "unqualified",
            approvalMode: mode, nodeDigest: try ACPLaunchContentIdentity.fileDigest(node), sourceCommit: source,
            executable: executable, packageRoot: root, helper: helper.resolvingSymlinksInPath(), nodeExecutable: node,
            routingDigest: routing.digest)
    }

    private static func packageContaining(_ executable: URL, named name: String) throws -> (URL, [String: Any]) {
        var directory = executable.deletingLastPathComponent()
        while directory.path != "/" {
            let manifest = directory.appendingPathComponent("package.json")
            if FileManager.default.fileExists(atPath: manifest.path),
               let value = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any],
               value["name"] as? String == name { return (directory, value) }
            directory.deleteLastPathComponent()
        }
        throw IdentityError.unownedExecutable
    }

    private struct Routing {
        let allowed: Bool
        let mode: String?
        let digest: String
    }

    private static func routingConfiguration(environment: [String: String], cwd: URL?, agent: String) throws -> Routing {
        var allowed = !alternateProviderKeys.contains(where: { !(environment[$0] ?? "").isEmpty })
        if let provider = environment["MODEL_PROVIDER"], !provider.isEmpty, provider != "openai" { allowed = false }
        guard let home = environment["HOME"], home.hasPrefix("/") else { throw IdentityError.configurationUnavailable }
        if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty,
           URL(fileURLWithPath: codexHome).resolvingSymlinksInPath().path != URL(fileURLWithPath: home).appendingPathComponent(".codex").resolvingSymlinksInPath().path { allowed = false }
        var hash = SHA256()
        func append(_ bytes: Data) {
            var size = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &size) { hash.update(bufferPointer: $0) }
            hash.update(data: bytes)
        }
        // Only a stamp leaves this scope. Configuration and credentials are never logged.
        for key in environment.keys.sorted() {
            append(Data(key.utf8))
            append(Data(environment[key]!.utf8))
        }
        var directories = [URL(fileURLWithPath: home)]
        var directory = cwd?.standardizedFileURL
        while let current = directory, current.path != "/" {
            if !directories.contains(where: { $0.path == current.path }) { directories.append(current) }
            directory = current.deletingLastPathComponent()
        }
        var mode: String?
        for directory in directories {
            let names = agent == "codex" ? [".codex/config.toml"] : [".claude/settings.json", ".claude/settings.local.json"]
            for name in names {
                let file = directory.appendingPathComponent(name)
                append(Data(file.path.utf8))
                guard FileManager.default.fileExists(atPath: file.path) else { append(Data())
                continue }
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                let bytes = try handle.read(upToCount: 1_048_577) ?? Data()
                guard bytes.count <= 1_048_576 else { throw IdentityError.configurationUnavailable }
                append(bytes)
                if agent == "codex" {
                    guard let text = String(data: bytes, encoding: .utf8) else { throw IdentityError.configurationUnavailable }
                    for line in text.components(separatedBy: .newlines).map({ $0.trimmingCharacters(in: .whitespaces) }) where !line.hasPrefix("#") {
                        // Escaped/ambiguous configuration stays unqualified rather than
                        // guessing which provider Codex's TOML reader will select.
                        if line.contains("\\") || line.contains("base_url") || line.contains("model_providers") || line.hasPrefix("profile") { allowed = false }
                        if line.contains("model_provider"), line.range(of: #"^model_provider\s*=\s*["']openai["']\s*(#.*)?$"#, options: .regularExpression) == nil { allowed = false }
                    }
                } else {
                    guard let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw IdentityError.configurationUnavailable }
                    if value["apiKeyHelper"] != nil || value["awsCredentialExport"] != nil { allowed = false }
                    if let env = value["env"] as? [String: Any], env.keys.contains(where: { alternateProviderKeys.contains($0) || injectedExecutionKeys.contains($0) }) { allowed = false }
                    if let permissions = value["permissions"] as? [String: Any], let selected = permissions["defaultMode"] as? String { mode = selected }
                }
            }
        }
        return .init(allowed: allowed, mode: mode, digest: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private static func authenticatedProvider(_ identity: ACPV2PreviewLaunchIdentity, environment: [String: String], cwd: URL?) async -> String {
        do {
            if identity.agentID == "codex" {
                let cli = identity.packageRoot.appendingPathComponent("node_modules/@openai/codex/bin/codex.js")
                guard cli.resolvingSymlinksInPath().path.hasPrefix(identity.packageRoot.path + "/") else { return "unverified" }
                let result = try await Process.run(identity.nodeExecutable.path, args: [cli.path, "login", "status"], cwd: cwd,
                    env: environment, timeout: 10)
                let lines = (result.stdout + "\n" + result.stderr).components(separatedBy: .newlines)
                return result.exitCode == 0 && lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == "Logged in using ChatGPT" }) ? "openai-chatgpt" : "unverified"
            }
            #if arch(arm64)
            let suffix = "darwin-arm64"
            #else
            let suffix = "darwin-x64"
            #endif
            let cli = identity.packageRoot.appendingPathComponent("node_modules/@anthropic-ai/claude-agent-sdk-\(suffix)/claude")
            guard cli.resolvingSymlinksInPath().path.hasPrefix(identity.packageRoot.path + "/") else { return "unverified" }
            let result = try await Process.run(cli.path, args: ["auth", "status", "--json"], cwd: cwd, env: environment, timeout: 10)
            guard result.exitCode == 0, let value = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
                  value["loggedIn"] as? Bool == true, value["authMethod"] as? String == "claude.ai", value["apiProvider"] as? String == "firstParty" else { return "unverified" }
            return "anthropic-claude-ai"
        } catch { return "unverified" }
    }
}
