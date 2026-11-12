import Foundation
import Testing
import AlasCore

@Suite("Codex MCP requirements probe")
struct CodexMCPRequirementsProbeTests {
    /// `codex mcp list --json` with an unrelated server and an `alas` entry.
    private static func listing(enabled: Bool, reason: String?) throws -> Data {
        let entries: [[String: Any]] = [
            ["name": "other", "enabled": false, "disabled_reason": "requirements (other source)"],
            ["name": "alas", "enabled": enabled, "disabled_reason": reason.map { $0 as Any } ?? NSNull()],
        ]
        return try JSONSerialization.data(withJSONObject: entries)
    }

    @Test("reports the source only when requirements disable the named server", arguments: [
        ("alas", false, "requirements (enterprise-managed requirements Baseline (7225))",
         "enterprise-managed requirements Baseline (7225)"),
        ("alas", false, "requirements", "requirements"),
        ("alas", false, "unknown", nil),
        ("alas", true, nil, nil),
        ("absent", false, "requirements (source)", nil),
    ] as [(String, Bool, String?, String?)])
    func blockSource(serverName: String, enabled: Bool, reason: String?, expected: String?) throws {
        let json = try Self.listing(enabled: enabled, reason: reason)
        #expect(CodexMCPRequirementsProbe.blockSource(listJSON: json, serverName: serverName) == expected)
    }

    @Test("an unreadable listing is not a block")
    func unreadableListing() {
        #expect(CodexMCPRequirementsProbe.blockSource(listJSON: Data("error: boom".utf8), serverName: "alas") == nil)
    }

    @Test("an HTTP server is described by its URL and never by its credentials")
    func httpOverrides() {
        let overrides = CodexMCPRequirementsProbe.configOverrides(for: .http(
            name: "localhost_with_path",
            url: "http://localhost:5599/mcp",
            headers: [.init(name: "Authorization", value: "Bearer TOK")]
        ))
        #expect(overrides == ["-c", #"mcp_servers.localhost_with_path.url="http://localhost:5599/mcp""#])
    }

    @Test("a stdio server is described by its command and arguments")
    func stdioOverrides() {
        let overrides = CodexMCPRequirementsProbe.configOverrides(for: .stdio(
            name: "alas",
            command: #"/Users/a "b"/Application Support/Alas/bin/alas"#,
            args: ["mcp"],
            env: [.init(name: "ALAS_SESSION_ID", value: "s")]
        ))
        #expect(overrides == [
            "-c", #"mcp_servers.alas.command="/Users/a \"b\"/Application Support/Alas/bin/alas""#,
            "-c", #"mcp_servers.alas.args=["mcp"]"#,
        ])
    }

    @Test("a server that cannot be written as an override is not probed", arguments: [
        ACPMCPServer.http(name: "dotted.name", url: "http://localhost:1/mcp", headers: []),
        .stdio(name: "alas", command: "/bin/alas\n", args: [], env: []),
        .stdio(name: "alas", command: "/bin/alas", args: ["a\u{0}b"], env: []),
    ])
    func unwritableOverrides(server: ACPMCPServer) {
        #expect(CodexMCPRequirementsProbe.configOverrides(for: server) == nil)
    }

    @Test("finds the Codex CLI of the package behind npm's bin symlink")
    func codexCLIBehindBinSymlink() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("alas-codex-probe-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let package = root.appendingPathComponent("lib/node_modules/@alas-ide/codex-acp")
        let entry = package.appendingPathComponent("dist/index.js")
        let cli = package.appendingPathComponent("node_modules/@openai/codex/bin/codex.js")
        let bin = root.appendingPathComponent("bin")
        for file in [entry, cli] {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        }
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: bin.appendingPathComponent("codex-acp"), withDestinationURL: entry)

        let found = CodexMCPRequirementsProbe.codexCLI(adapterCommand: bin.appendingPathComponent("codex-acp").path)
        #expect(found?.resolvingSymlinksInPath().path == cli.resolvingSymlinksInPath().path)
        #expect(CodexMCPRequirementsProbe.codexCLI(adapterCommand: bin.appendingPathComponent("missing").path) == nil)
        #expect(CodexMCPRequirementsProbe.codexCLI(adapterCommand: "codex-acp") == nil)
    }
}
