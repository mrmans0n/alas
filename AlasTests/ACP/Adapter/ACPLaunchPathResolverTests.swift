import Foundation
import Testing
@testable import Alas

@Suite("ACPLaunchPathResolver")
struct ACPLaunchPathResolverTests {
    private func makeExecutable(named name: String, inDir dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let exe = dir.appendingPathComponent(name)
        try "#!/bin/sh\nexit 0\n".write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        return exe
    }

    private func tmp() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-launchpath-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeNpmReturning(_ root: URL, inDir dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let npm = dir.appendingPathComponent("npm")
        let prefix = root.deletingLastPathComponent()
        try """
        #!/bin/sh
        if [ "$1 $2" = "root -g" ]; then printf '%s\\n' '\(root.path)'; exit 0; fi
        if [ "$1 $2" = "prefix -g" ]; then printf '%s\\n' '\(prefix.path)'; exit 0; fi
        exit 1
        """.write(to: npm, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: npm.path)
        return npm
    }

    private func makeOwnedExecutable(
        named name: String,
        package: String,
        inBinDirectory binDirectory: URL
    ) throws -> URL {
        let packageExecutable = binDirectory.deletingLastPathComponent()
            .appendingPathComponent("lib/node_modules/\(package)/dist/index.js")
        _ = try makeExecutable(
            named: packageExecutable.lastPathComponent,
            inDir: packageExecutable.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let link = binDirectory.appendingPathComponent(name)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: packageExecutable)
        return link
    }

    @Test("non-npm adapter resolves to nil (PATH launch unchanged)")
    func nonNpmReturnsNil() async throws {
        let gemini = try #require(ACPLaunchCatalog.spec(for: "gemini"))   // .binaryOnPath, npmPackageName == nil
        let resolver = ACPLaunchPathResolver(
            env: ["PATH": "/usr/bin"], additionalPathDirectories: [],
            npmGlobalBinDirectory: { nil })
        let path = await resolver.resolvedLaunchPath(for: gemini)
        #expect(path == nil)
    }

    // codex is `.npxPackage` — the package is the only thing the setup check
    // verifies, so the resolver prefers the package-owned binary (shadow defeat).
    @Test("npxPackage adapter: npm-global binary beats a PATH shadow")
    func npmGlobalWinsOverShadow() async throws {
        let pathDir = tmp()
        let npmBinDir = tmp()
        let shadow = try makeExecutable(named: "codex-acp", inDir: pathDir)
        let owned = try makeOwnedExecutable(
            named: "codex-acp",
            package: "@alas-ide/codex-acp",
            inBinDirectory: npmBinDir)
        defer {
            try? FileManager.default.removeItem(at: pathDir)
            try? FileManager.default.removeItem(at: npmBinDir)
        }
        let codex = try #require(ACPLaunchCatalog.spec(for: "codex"))
        let resolver = ACPLaunchPathResolver(
            env: ["PATH": pathDir.path], additionalPathDirectories: [],
            npmGlobalBinDirectory: { npmBinDir.path })
        let path = await resolver.resolvedLaunchPath(for: codex)
        #expect(path == owned.path)
        #expect(path != shadow.path)
    }

    @Test("npxPackage does not fall back to a same-named PATH binary")
    func packageOnlyRejectsPathFallback() async throws {
        let pathDir = tmp()
        let onPath = try makeExecutable(named: "codex-acp", inDir: pathDir)
        defer { try? FileManager.default.removeItem(at: pathDir) }
        let codex = try #require(ACPLaunchCatalog.spec(for: "codex"))
        let resolver = ACPLaunchPathResolver(
            env: ["PATH": pathDir.path], additionalPathDirectories: [],
            npmGlobalBinDirectory: { nil })   // npm-global unavailable
        let path = await resolver.resolvedLaunchPath(for: codex)
        #expect(path == nil)
        #expect(FileManager.default.isExecutableFile(atPath: onPath.path))
    }

    // Pi uses `.binaryOnPathOrNpmPackage`: the check resolves PATH first, so
    // the resolver launches the same binary when both candidates exist.
    @Test("binaryOnPathOrNpmPackage adapter: PATH binary wins over npm-global")
    func binaryVerifiedPrefersPath() async throws {
        let pathDir = tmp()
        let npmBinDir = tmp()
        let onPath = try makeExecutable(named: "pi-acp", inDir: pathDir)
        let inNpm = try makeExecutable(named: "pi-acp", inDir: npmBinDir)
        defer {
            try? FileManager.default.removeItem(at: pathDir)
            try? FileManager.default.removeItem(at: npmBinDir)
        }
        let pi = try #require(ACPLaunchCatalog.spec(for: "pi"))
        let resolver = ACPLaunchPathResolver(
            env: ["PATH": pathDir.path], additionalPathDirectories: [],
            npmGlobalBinDirectory: { npmBinDir.path })
        let path = await resolver.resolvedLaunchPath(for: pi)
        #expect(path == onPath.path)
        #expect(path != inNpm.path)
    }

    @Test("binaryOnPathOrNpmPackage adapter: falls back to npm-global when no PATH binary")
    func binaryVerifiedFallsBackToNpmGlobal() async throws {
        let npmBinDir = tmp()
        let inNpm = try makeExecutable(named: "pi-acp", inDir: npmBinDir)
        defer { try? FileManager.default.removeItem(at: npmBinDir) }
        let pi = try #require(ACPLaunchCatalog.spec(for: "pi"))
        let resolver = ACPLaunchPathResolver(
            env: ["PATH": "/var/empty"], additionalPathDirectories: [],
            npmGlobalBinDirectory: { npmBinDir.path })
        let path = await resolver.resolvedLaunchPath(for: pi)
        #expect(path == inNpm.path)
    }

    @Test("nil when nothing resolves")
    func nothingResolves() async throws {
        let codex = try #require(ACPLaunchCatalog.spec(for: "codex"))
        let resolver = ACPLaunchPathResolver(
            env: ["PATH": "/var/empty"], additionalPathDirectories: [],
            npmGlobalBinDirectory: { nil })
        let path = await resolver.resolvedLaunchPath(for: codex)
        #expect(path == nil)
    }

    @Test("Claude requires the Alas package even when a legacy package and binary exist")
    func claudeRequiresDownstreamPackage() async throws {
        let tempDir = tmp()
        let pathDir = tempDir.appendingPathComponent("bin", isDirectory: true)
        let modules = tempDir.appendingPathComponent("node_modules", isDirectory: true)
        let claudeBinary = try makeExecutable(named: "claude-agent-acp", inDir: pathDir)
        _ = try makeNpmReturning(modules, inDir: pathDir)
        let legacyPackage = modules.appendingPathComponent("@agentclientprotocol/claude-agent-acp", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyPackage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let claude = try #require(ACPLaunchCatalog.spec(for: "claude"))
        let checker = ACPSetupChecker(env: ["PATH": pathDir.path], additionalPathDirectories: [])
        #expect(claude.setupCheck == .npxPackage(name: "@alas-ide/claude-agent-acp"))
        #expect(await checker.evaluate(claude.setupCheck) == .missing(
            reason: "npm package `@alas-ide/claude-agent-acp` is not installed globally"))
        #expect(FileManager.default.isExecutableFile(atPath: claudeBinary.path))

        let downstreamPackage = modules.appendingPathComponent("@alas-ide/claude-agent-acp", isDirectory: true)
        try FileManager.default.createDirectory(at: downstreamPackage, withIntermediateDirectories: true)
        try #"{"bin":{"claude-agent-acp":"dist/index.js"}}"#
            .write(to: downstreamPackage.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        _ = try makeExecutable(
            named: "index.js",
            inDir: downstreamPackage.appendingPathComponent("dist", isDirectory: true))
        #expect(await checker.evaluate(claude.setupCheck) == .missing(
            reason: "npm package `@alas-ide/claude-agent-acp` is not installed globally"))
        try FileManager.default.removeItem(at: claudeBinary)
        try FileManager.default.createSymbolicLink(
            at: claudeBinary,
            withDestinationURL: downstreamPackage.appendingPathComponent("dist/index.js"))
        #expect(await checker.evaluate(claude.setupCheck) == .ready)
    }

    @Test("managed package requires its declared executable")
    func packageRequiresDeclaredExecutable() async throws {
        let tempDir = tmp()
        let pathDir = tempDir.appendingPathComponent("bin", isDirectory: true)
        let modules = tempDir.appendingPathComponent("node_modules", isDirectory: true)
        let package = modules.appendingPathComponent("@alas-ide/codex-acp", isDirectory: true)
        _ = try makeExecutable(named: "codex-acp", inDir: pathDir)
        _ = try makeNpmReturning(modules, inDir: pathDir)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try #"{"bin":{"codex-acp":"dist/index.js"}}"#
            .write(to: package.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let codex = try #require(ACPLaunchCatalog.spec(for: "codex"))
        let checker = ACPSetupChecker(env: ["PATH": pathDir.path], additionalPathDirectories: [])

        #expect(await checker.evaluate(codex.setupCheck) == .missing(
            reason: "npm package `@alas-ide/codex-acp` is not installed globally"))
    }

    @Test("explicit Claude executable override checks its configured binary")
    func customClaudeExecutableOverrideChecksConfiguredBinary() async throws {
        let pathDir = tmp()
        let customBinary = try makeExecutable(named: "custom-claude-acp", inDir: pathDir)
        defer { try? FileManager.default.removeItem(at: pathDir) }

        let claude = try #require(ACPLaunchCatalog.spec(for: "claude"))
            .overridingCommandAndSetupCheck("custom-claude-acp")
        let checker = ACPSetupChecker(env: ["PATH": pathDir.path], additionalPathDirectories: [])
        let resolver = ACPLaunchPathResolver(
            env: ["PATH": pathDir.path], additionalPathDirectories: [],
            npmGlobalBinDirectory: { nil })

        #expect(claude.setupCheck == .binaryOnPath(name: "custom-claude-acp"))
        #expect(await checker.evaluate(claude.setupCheck) == .ready)
        #expect(await resolver.resolvedLaunchPath(for: claude) == nil)
        #expect(FileManager.default.isExecutableFile(atPath: customBinary.path))
    }
}
