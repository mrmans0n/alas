import CryptoKit
import Foundation
import Testing
import AlasCore

struct ACPV2PreviewEligibilityTests {
    @Test(arguments: ["allowed", "release", "disabled", "intent", "remote", "history", "lease", "empty", "version", "provider", "mode", "helper", "node", "capabilities"])
    func previewAdmissionRequiresEveryExplicitGate(gate: String) {
        let identity = Self.identity(version: gate == "version" ? "unknown" : "2.5.0-alas.6",
            helper: gate == "helper" ? "changed" : "helper", provider: gate == "provider" ? "gateway" : "openai-chatgpt",
            mode: gate == "mode" ? "bypass" : "read-only", node: gate == "node" ? "changed" : "node")
        let record = Self.record(Self.identity(), capabilities: gate == "capabilities" ? [] : Self.capabilities)
        let result = ACPV2PreviewEligibility.evaluate(identity: identity, records: gate == "empty" ? [] : [record],
            debugBuild: gate != "release", experimentalEnabled: gate != "disabled", explicitPreview: gate != "intent",
            local: gate != "remote", fresh: gate != "history", writerLeaseCurrent: gate != "lease")
        if gate == "allowed" { #expect(result == .allowed(record)) }
        else {
            let expected: ACPV2PreviewAdmission.Reason = switch gate {
            case "release", "disabled": .disabled
            case "intent": .missingIntent
            case "remote": .remote
            case "history": .notFresh
            case "lease": .staleLease
            case "provider": .unsupportedProvider
            case "mode": .unsupportedMode
            default: .unqualifiedIdentity
            }
            #expect(result == .refused(expected))
        }
    }

    @Test func changedPackageContentInvalidatesTheSameVersion() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let before = try await ACPV2PreviewEligibility.resolveIdentity(launchSpec: fixture.spec(), helperURL: fixture.helper, environment: fixture.environment, cwd: fixture.root)
        try Data("other".utf8).write(to: fixture.dependency)
        let after = try await ACPV2PreviewEligibility.resolveIdentity(launchSpec: fixture.spec(), helperURL: fixture.helper, environment: fixture.environment, cwd: fixture.root)
        #expect(before.packageVersion == after.packageVersion)
        #expect(before.packageDigest != after.packageDigest)
        #expect(before != after)
        #expect(ACPV2PreviewEligibility.evaluate(identity: after, records: [Self.record(before)], debugBuild: true,
            experimentalEnabled: true, explicitPreview: true, local: true, fresh: true, writerLeaseCurrent: true) == .refused(.unqualifiedIdentity))
        #expect(!FileManager.default.fileExists(atPath: fixture.executionMarker.path))
    }

    @Test(arguments: ["relative", "custom", "arguments", "entry-link", "dependency-link", "node-options", "executable-override"])
    func launchIdentityRejectsUnownedOrMutableCommands(kind: String) async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        if kind == "entry-link" {
            try FileManager.default.removeItem(at: fixture.entry)
            try FileManager.default.createSymbolicLink(at: fixture.entry, withDestinationURL: fixture.helper)
        }
        if kind == "dependency-link" {
            try FileManager.default.createSymbolicLink(at: fixture.package.appendingPathComponent("escape"), withDestinationURL: fixture.root)
        }
        var environment = fixture.environment
        if kind == "node-options" { environment["NODE_OPTIONS"] = "--require=/unqualified" }
        if kind == "executable-override" { environment["CODEX_PATH"] = "/unqualified" }
        await #expect(throws: (any Error).self) {
            try await ACPV2PreviewEligibility.resolveIdentity(launchSpec: fixture.spec(command: kind == "relative" ? "codex-acp" : fixture.entry.path,
                arguments: kind == "arguments" ? ["--custom"] : [], custom: kind == "custom"), helperURL: fixture.helper, environment: environment, cwd: fixture.root)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.executionMarker.path))
    }

    private static let capabilities = ["freshSessionV2", "textPrompt", "permissionAllowOnce", "permissionCancel"]
    private static func identity(version: String = "2.5.0-alas.6", helper: String = "helper", provider: String = "openai-chatgpt", mode: String = "read-only", node: String = "node") -> ACPV2PreviewLaunchIdentity {
        .init(agentID: "codex", packageName: "@alas-ide/codex-acp", packageVersion: version,
            packageDigest: "package", helperDigest: helper, providerID: provider, approvalMode: mode, nodeDigest: node,
            sourceCommit: String(repeating: "d", count: 40), executable: URL(fileURLWithPath: "/qualified/dist/index.js"),
            packageRoot: URL(fileURLWithPath: "/qualified"), helper: URL(fileURLWithPath: "/helper"),
            nodeExecutable: URL(fileURLWithPath: "/node"), routingDigest: "routing")
    }
    private static func record(_ identity: ACPV2PreviewLaunchIdentity, capabilities: [String] = capabilities) -> ACPV2PreviewQualifiedAdapter {
        .init(agentID: identity.agentID, packageName: identity.packageName, packageVersion: identity.packageVersion,
            packageDigest: identity.packageDigest, helperDigest: identity.helperDigest, providerID: "openai-chatgpt",
            approvalMode: "read-only", nodeDigest: identity.nodeDigest, nodeVersion: "v26.13.0",
            sourceRepository: "https://github.com/mrmans0n/codex-acp", sourceCommit: identity.sourceCommit,
            packageIntegrity: "verified", supportedCapabilities: capabilities)
    }

    private struct Fixture {
        let root: URL
        let package: URL
        let entry: URL
        let dependency: URL
        let helper: URL
        let node: URL
        let executionMarker: URL
        var environment: [String: String] { ["HOME": root.appendingPathComponent("home").path, "PATH": node.deletingLastPathComponent().path, "INITIAL_AGENT_MODE": "read-only"] }
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            package = root.appendingPathComponent("package")
            entry = package.appendingPathComponent("dist/index.js")
            dependency = package.appendingPathComponent("node_modules/dependency/index.js")
            helper = root.appendingPathComponent("helper")
            node = root.appendingPathComponent("bin/node")
            executionMarker = root.appendingPathComponent("executed")
            for directory in [entry.deletingLastPathComponent(), dependency.deletingLastPathComponent(), node.deletingLastPathComponent(), root.appendingPathComponent("home")] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try Data("""
            {"name":"@alas-ide/codex-acp","version":"2.5.0-alas.6","bin":{"codex-acp":"dist/index.js"},"alasDownstream":{"sourceCommit":"\(String(repeating: "d", count: 40))"}}
            """.utf8).write(to: package.appendingPathComponent("package.json"))
            try Data("#!/usr/bin/env node\n".utf8).write(to: entry)
            try Data("first".utf8).write(to: dependency)
            try Data("helper".utf8).write(to: helper)
            try Data("#!/bin/sh\nprintf unexpected > \(executionMarker.path)\n".utf8).write(to: node)
            for executable in [entry, helper, node] { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path) }
        }
        func spec(command: String? = nil, arguments: [String] = [], custom: Bool = false) -> ACPLaunchSpec {
            .init(agentID: "codex", command: command ?? entry.path, arguments: arguments, extraEnv: [:],
                setupCheck: custom ? .binaryOnPath(name: "custom") : .npxPackage(name: "@alas-ide/codex-acp"),
                supportsModelSelection: true, supportsModeSelection: true)
        }
    }
}
