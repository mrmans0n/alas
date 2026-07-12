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
        #expect(script.contains("cd '\\''/srv/repo'\\'' && "))
        #expect(script.contains("rg"))
        #expect(script.contains("--json"))
        #expect(script.contains("needle"))
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

    @Test func gitGrepUsesExtendedRegexWhenRegexSearchIsEnabled() {
        let args = RemoteContentSearch.gitGrepArgs(query: "foo|bar", options: SearchContentOptions(regex: true))

        #expect(args.contains("-E"))
        #expect(!args.contains("-F"))
    }

    @Test func cappedGitGrepInvocationLimitsOutputOnRemoteSide() {
        let invocation = RemoteContentSearch.cappedGitGrepInvocation(
            host: "devbox",
            cwd: "/srv/repo",
            query: "needle",
            options: SearchContentOptions()
        )

        #expect(invocation.executable == "/usr/bin/ssh")
        #expect(invocation.args.contains("BatchMode=yes"))
        let script = invocation.args.last ?? ""
        #expect(script.contains("cd '\\''/srv/repo'\\'' && "))
        #expect(script.contains("mkfifo \"$fifo\" || exit 2"))
        #expect(script.contains("env GIT_OPTIONAL_LOCKS=0 LC_ALL=C git '\\''grep'\\''"))
        #expect(script.contains("awk -v cap=2000"))
        #expect(script.contains("if (NR >= cap) exit"))
        #expect(script.contains("git_status=$?"))
        #expect(script.contains("exit \"$git_status\""))
    }

    @Test func parsesNulSeparatedGrepLine() {
        let line = "src/a:b.txt\u{0}12\u{0}5\u{0}let value = needle"
        let hit = RemoteContentSearch.parseGitGrepLine(line)
        #expect(hit?.path == "src/a:b.txt")
        #expect(hit?.line == 12)
        #expect(hit?.column == 5)
        #expect(hit?.text == "let value = needle")
    }

    @Test func rejectsMalformedGrepLines() {
        #expect(RemoteContentSearch.parseGitGrepLine("") == nil)
        #expect(RemoteContentSearch.parseGitGrepLine("no-nul-here:1:2:x") == nil)
        #expect(RemoteContentSearch.parseGitGrepLine("p\u{0}notanumber\u{0}2\u{0}x") == nil)
    }
}
