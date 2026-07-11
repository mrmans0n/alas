import Testing
@testable import Alas

struct RemoteLSPLauncherTests {
    @Test func invocationRunsServerInWorkspaceRootWithEnv() {
        let invocation = RemoteLSPLauncher.invocation(
            host: "devbox",
            rootPath: "/srv/repo",
            command: "rust-analyzer",
            args: [],
            env: ["RA_LOG": "error"]
        )

        #expect(invocation.executable == "/usr/bin/ssh")
        #expect(invocation.args.contains("BatchMode=yes"))
        let script = invocation.args.last ?? ""
        #expect(script.contains("cd '\\''/srv/repo'\\'' && "))
        #expect(script.contains("'RA_LOG=error'"))
        #expect(script.contains("exec env 'RA_LOG=error' 'rust-analyzer'")
            || script.contains("'rust-analyzer'"))
    }

    @Test func invocationWithoutEnvHasNoEnvPrefix() {
        let invocation = RemoteLSPLauncher.invocation(
            host: "devbox",
            rootPath: "/srv/repo",
            command: "typescript-language-server",
            args: ["--stdio"],
            env: [:]
        )

        let script = invocation.args.last ?? ""
        #expect(!script.contains(" env "))
        #expect(script.contains("typescript-language-server"))
        #expect(script.contains("--stdio"))
        #expect(script.contains("exec "))
    }

    @Test func sourceKitProbeFallsBackToXcrun() {
        #expect(RemoteLSPLauncher.availabilityProbeCommand(command: "sourcekit-lsp")
            == "command -v 'sourcekit-lsp' >/dev/null 2>&1 || xcrun --find 'sourcekit-lsp' >/dev/null 2>&1")
    }

    @Test func availabilityProbeRunsWithConfiguredEnvironment() {
        let command = RemoteLSPLauncher.availabilityProbeCommand(
            command: "custom-lsp",
            env: ["PATH": "/opt/lsp/bin:$PATH"]
        )

        #expect(command.contains("env 'PATH=/opt/lsp/bin:$PATH' sh -c"))
        #expect(command.contains("command -v '\\''custom-lsp'\\''"))
    }

    @Test func sourceKitInvocationUsesResolvedRemotePath() {
        let invocation = RemoteLSPLauncher.invocation(
            host: "devbox",
            rootPath: "/srv/repo",
            command: "sourcekit-lsp",
            args: [],
            env: [:]
        )

        let script = invocation.args.last ?? ""
        #expect(script.contains("xcrun --find"))
        #expect(script.contains("sourcekit-lsp"))
        #expect(script.contains("exec \"$resolved_lsp\""))
    }

    @Test func sourceKitResolutionUsesConfiguredEnvironment() {
        let invocation = RemoteLSPLauncher.invocation(
            host: "devbox",
            rootPath: "/srv/repo",
            command: "sourcekit-lsp",
            args: [],
            env: ["PATH": "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin"]
        )

        let script = invocation.args.last ?? ""
        #expect(script.contains("PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin"))
        #expect(script.contains("sh -c"))
        #expect(script.contains("xcrun --find"))
        #expect(script.contains("exec env"))
        #expect(script.contains("\"$resolved_lsp\""))
    }
}
