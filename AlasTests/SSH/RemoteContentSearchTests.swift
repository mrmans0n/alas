import Testing
@testable import Alas

struct RemoteContentSearchTests {
    @Test func rgInvocationRunsBatchSSHInWorktree() {
        let invocation = RemoteContentSearch.rgInvocation(
            host: "devbox",
            cwd: "/srv/repo",
            rgArgs: ["--json", "--", "needle", "."]
        )

        #expect(invocation.executable == "/usr/bin/ssh")
        #expect(invocation.args.contains("BatchMode=yes"))
        let script = invocation.args.last ?? ""
        #expect(script.hasPrefix("cd -- '/srv/repo' && "))
        #expect(script.contains("rg '--json' '--' 'needle' '.'"))
    }

    @Test func gitGrepEmulatesSmartCase() {
        #expect(RemoteContentSearch.gitGrepArgs(
            query: "needle", options: SearchContentOptions()
        ).contains("-i"))
        #expect(!RemoteContentSearch.gitGrepArgs(
            query: "Needle", options: SearchContentOptions()
        ).contains("-i"))
    }

    @Test func gitGrepAlwaysSearchesUntrackedAndSkipsBinary() {
        let args = RemoteContentSearch.gitGrepArgs(query: "x", options: SearchContentOptions())
        #expect(args.first == "grep")
        for flag in ["-nI", "--column", "--untracked", "-z"] {
            #expect(args.contains(flag))
        }
    }

    @Test func parsesNulSeparatedGrepLine() {
        let line = "src/a:b.txt\u{0}12:5:let value = needle"
        let hit = RemoteContentSearch.parseGitGrepLine(line)
        #expect(hit?.path == "src/a:b.txt")
        #expect(hit?.line == 12)
        #expect(hit?.column == 5)
        #expect(hit?.text == "let value = needle")
    }

    @Test func rejectsMalformedGrepLines() {
        #expect(RemoteContentSearch.parseGitGrepLine("") == nil)
        #expect(RemoteContentSearch.parseGitGrepLine("no-nul-here:1:2:x") == nil)
        #expect(RemoteContentSearch.parseGitGrepLine("p\u{0}notanumber:2:x") == nil)
    }
}
