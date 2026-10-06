import CryptoKit
import Foundation
import Testing
@testable import Alas

@Suite("ACP registry")
struct ACPRegistryTests {
    // MARK: - Index and plans

    @Test func indexDecodingSkipsMalformedEntries() throws {
        let json = """
        {
          "version": "1.0.0",
          "agents": [
            {
              "id": "opencode", "name": "OpenCode", "version": "1.18.34",
              "description": "The open source coding agent", "license_url": "https://x",
              "distribution": { "binary": { "darwin-aarch64": {
                "archive": "https://example.com/opencode.zip", "cmd": "./opencode",
                "args": ["acp"], "sha256": "ab"
              } } }
            },
            { "id": "broken", "name": "Broken", "version": "1.0.0", "description": "no distribution" },
            {
              "id": "fast-agent", "name": "fast-agent", "version": "0.10.1",
              "description": "uv agent", "license_url": "https://x",
              "distribution": { "uvx": { "package": "fast-agent-acp==0.10.1", "args": ["-x"],
                "env": { "FAST_AGENT_MODEL": "codexplan" } } },
              "preview": { "version": "0.11.0-preview.1", "distribution": { "uvx": { "package": "fast-agent-acp==0.11.0" } } }
            }
          ]
        }
        """
        let index = try JSONDecoder().decode(ACPRegistryIndex.self, from: Data(json.utf8))

        #expect(index.agents.map(\.id) == ["opencode", "fast-agent"])
        #expect(index.agents[0].distribution.binary?["darwin-aarch64"]?.args == ["acp"])
        #expect(index.agents[1].distribution.uvx?.env == ["FAST_AGENT_MODEL": "codexplan"])
    }

    @Test(arguments: [
        // Native binary for this platform wins over packages.
        (ACPRegistryTests.agent(binaryPlatforms: ["darwin-aarch64"], npx: true, uvx: true), "binary"),
        // A binary for another platform is not runnable; fall back to npm, then uv.
        (ACPRegistryTests.agent(binaryPlatforms: ["linux-x86_64"], npx: true, uvx: true), "npm"),
        (ACPRegistryTests.agent(binaryPlatforms: ["darwin-x86_64"], npx: false, uvx: true), "uv"),
        (ACPRegistryTests.agent(binaryPlatforms: ["linux-aarch64"], npx: false, uvx: false), nil),
    ] as [(ACPRegistryAgent, String?)])
    func installPlanPrefersPlatformBinaryThenNpmThenUv(agent: ACPRegistryAgent, expected: String?) {
        #expect(agent.installPlan(platform: "darwin-aarch64")?.label == expected)
    }

    @Test func entryStatusKeepsCuratedAgentsBuiltinAndTracksInstalledVersion() {
        let installed = [Self.record(registryID: "goose", version: "1.0.0")]

        #expect(ACPRegistryEntryStatus.resolve(
            agent: Self.agent(id: "claude-acp", npx: true), installed: [], platform: "darwin-aarch64"
        ) == .builtin(agentID: "claude"))
        #expect(ACPRegistryEntryStatus.resolve(
            agent: Self.agent(id: "goose", version: "1.0.0", npx: true), installed: installed, platform: "darwin-aarch64"
        ) == .installed)
        #expect(ACPRegistryEntryStatus.resolve(
            agent: Self.agent(id: "goose", version: "1.1.0", npx: true), installed: installed, platform: "darwin-aarch64"
        ) == .updateAvailable(installedVersion: "1.0.0"))
        #expect(ACPRegistryEntryStatus.resolve(
            agent: Self.agent(id: "amp", npx: true), installed: installed, platform: "darwin-aarch64"
        ) == .notInstalled)
        #expect(ACPRegistryEntryStatus.resolve(
            agent: Self.agent(id: "kimi", binaryPlatforms: ["linux-x86_64"]), installed: installed, platform: "darwin-aarch64"
        ) == .unsupported)
    }

    @Test func curatedRegistryAgentsMapToBuiltinLaunchSpecs() {
        let builtinIDs = Set(ACPLaunchCatalog.builtinSpecs.map(\.agentID))
        for builtinID in ACPRegistryCuratedAgents.builtinIDByRegistryID.values {
            #expect(builtinIDs.contains(builtinID), "\(builtinID) has no curated launch spec")
        }
    }

    // MARK: - Pure installer helpers

    @Test(arguments: [
        ("./opencode", "opencode"),
        ("./dist-package/cursor-agent", "dist-package/cursor-agent"),
        ("amp-acp", "amp-acp"),
    ])
    func relativeCommandPathAcceptsPathsInsideTheArchive(cmd: String, expected: String) throws {
        #expect(try ACPRegistryInstaller.relativeCommandPath(cmd) == expected)
    }

    @Test(arguments: ["", "./", "/usr/bin/env", "~/bin/agent", "../agent", "./bin/../../agent"])
    func relativeCommandPathRejectsPathsOutsideTheArchive(cmd: String) {
        #expect(throws: ACPRegistryInstallError.invalidCommand(cmd)) {
            try ACPRegistryInstaller.relativeCommandPath(cmd)
        }
    }

    @Test(arguments: [
        ("@agentclientprotocol/claude-agent-acp@0.85.1", "@agentclientprotocol/claude-agent-acp"),
        ("pi-acp@0.0.34", "pi-acp"),
        ("@scope/name", "@scope/name"),
        ("plain", "plain"),
    ])
    func npmPackageNameStripsTheVersion(spec: String, expected: String) {
        #expect(ACPRegistryInstaller.npmPackageName(fromSpec: spec) == expected)
    }

    @Test(arguments: [
        (#"{"bin": "dist/index.js"}"#, "@google/gemini-cli", "gemini-cli"),
        (#"{"bin": {"gemini": "dist/index.js"}}"#, "@google/gemini-cli", "gemini"),
        (#"{"bin": {"tool": "a.js", "pi-acp": "b.js"}}"#, "pi-acp", "pi-acp"),
    ])
    func npmExecutableNameFollowsNpxResolution(manifest: String, package: String, expected: String) throws {
        #expect(try ACPRegistryInstaller.npmExecutableName(manifest: Data(manifest.utf8), packageName: package) == expected)
    }

    @Test(arguments: [#"{"name": "lib"}"#, #"{"bin": {"a": "a.js", "b": "b.js"}}"#])
    func npmExecutableNameRejectsAmbiguousOrMissingBins(manifest: String) {
        #expect(throws: ACPRegistryInstallError.missingNpmExecutable("lib")) {
            try ACPRegistryInstaller.npmExecutableName(manifest: Data(manifest.utf8), packageName: "lib")
        }
    }

    // MARK: - Installs

    @Test func binaryInstallVerifiesChecksumAndKeepsWorkingInstallOnFailure() async throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveBytes = Data("archive".utf8)
        let checksum = SHA256.hash(data: archiveBytes).map { String(format: "%02x", $0) }.joined()
        let installer = ACPRegistryInstaller(
            root: root,
            platform: "darwin-aarch64",
            download: { _ in
                let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try archiveBytes.write(to: file)
                return file
            },
            runner: { command, args in
                // Stand-in for `tar -xf <archive> -C <dir>`: lay down a
                // non-executable binary so the installer must chmod it.
                #expect(command == "tar")
                let dir = URL(fileURLWithPath: args[3]).appendingPathComponent("bin")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try Data("#!/bin/sh\n".utf8).write(to: dir.appendingPathComponent("goose"))
                return (0, "")
            }
        )

        let record = try await installer.install(Self.binaryAgent(sha256: checksum))

        let expectedCommand = root.appendingPathComponent("goose/bin/goose").path
        #expect(record.command == expectedCommand)
        #expect(record.arguments == ["acp"])
        #expect(record.environment == ["GOOSE_MODE": "acp"])
        #expect(FileManager.default.isExecutableFile(atPath: expectedCommand))

        await #expect(throws: ACPRegistryInstallError.checksumMismatch) {
            try await installer.install(Self.binaryAgent(sha256: String(repeating: "0", count: 64)))
        }
        #expect(FileManager.default.isExecutableFile(atPath: expectedCommand))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["goose"])
    }

    @Test func npmInstallLaunchesThePackageBinFromItsOwnPrefix() async throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = ACPRegistryInstaller(
            root: root,
            platform: "darwin-aarch64",
            download: { _ in Issue.record("npm installs download nothing"); throw URLError(.badURL) },
            runner: { command, args in
                #expect(command == "npm")
                #expect(args.last == "@google/gemini-cli@0.62.0")
                let prefix = URL(fileURLWithPath: args[args.firstIndex(of: "--prefix")! + 1])
                let package = prefix.appendingPathComponent("node_modules/@google/gemini-cli")
                let bin = prefix.appendingPathComponent("node_modules/.bin")
                try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
                try Data(#"{"bin": {"gemini": "dist/index.js"}}"#.utf8)
                    .write(to: package.appendingPathComponent("package.json"))
                let executable = bin.appendingPathComponent("gemini")
                try Data("#!/bin/sh\n".utf8).write(to: executable)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
                return (0, "")
            }
        )
        let agent = ACPRegistryAgent(
            id: "gemini-registry", name: "Gemini CLI", version: "0.62.0", description: "d",
            website: nil, repository: nil,
            distribution: .init(
                binary: nil,
                npx: .init(package: "@google/gemini-cli@0.62.0", args: ["--acp"], env: nil),
                uvx: nil
            )
        )

        let record = try await installer.install(agent)

        #expect(record.command == root.appendingPathComponent("gemini-registry/node_modules/.bin/gemini").path)
        #expect(record.arguments == ["--acp"])
        #expect(record.launchSpec.agentID == "registry-gemini-registry")
    }

    // MARK: - Fixtures

    private static func agent(
        id: String = "agent",
        version: String = "1.0.0",
        binaryPlatforms: [String] = [],
        npx: Bool = false,
        uvx: Bool = false
    ) -> ACPRegistryAgent {
        let target = ACPRegistryAgent.BinaryTarget(
            archive: URL(string: "https://example.com/a.tar.gz")!, sha256: nil, cmd: "./a", args: nil, env: nil
        )
        let package = ACPRegistryAgent.Package(package: "pkg@1.0.0", args: nil, env: nil)
        return ACPRegistryAgent(
            id: id, name: id, version: version, description: "d", website: nil, repository: nil,
            distribution: .init(
                binary: binaryPlatforms.isEmpty ? nil : Dictionary(uniqueKeysWithValues: binaryPlatforms.map { ($0, target) }),
                npx: npx ? package : nil,
                uvx: uvx ? package : nil
            )
        )
    }

    private static func binaryAgent(sha256: String) -> ACPRegistryAgent {
        ACPRegistryAgent(
            id: "goose", name: "goose", version: "1.53.0", description: "d", website: nil, repository: nil,
            distribution: .init(
                binary: ["darwin-aarch64": .init(
                    archive: URL(string: "https://example.com/goose.tar.bz2")!,
                    sha256: sha256, cmd: "./bin/goose", args: ["acp"], env: ["GOOSE_MODE": "acp"]
                )],
                npx: nil, uvx: nil
            )
        )
    }

    private static func record(registryID: String, version: String) -> ACPRegistryInstalledAgent {
        ACPRegistryInstalledAgent(
            registryID: registryID, displayName: registryID, version: version,
            command: "/tmp/\(registryID)", arguments: [], environment: [:], isEnabled: true
        )
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("acp-registry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
