import Testing
@testable import Alas

struct RemoteWorktreePollTests {
    private let porcelain = """
    worktree /srv/repo
    HEAD 1111111111111111111111111111111111111111
    branch refs/heads/main

    worktree /srv/wt/feature
    HEAD 2222222222222222222222222222222222222222
    branch refs/heads/feature-x

    worktree /srv/wt/detached
    HEAD 3333333333333333333333333333333333333333
    detached
    """

    @Test func parsesEntriesWithBranchAndDetached() {
        let entries = RemoteWorktreePoll.parse(porcelain: porcelain)
        #expect(entries.count == 3)
        #expect(entries[0] == RemoteWorktreePollEntry(
            path: "/srv/repo",
            head: "1111111111111111111111111111111111111111",
            branch: "refs/heads/main"
        ))
        #expect(entries[2].branch == nil)
    }

    @Test func parseIgnoresBareAndUnknownLines() {
        let entries = RemoteWorktreePoll.parse(porcelain: "worktree /srv/bare\nbare\n")
        #expect(entries.count == 1)
        #expect(entries[0].head == "")
    }

    @Test func identicalSnapshotsClassifyAsNil() {
        let entries = RemoteWorktreePoll.parse(porcelain: porcelain)
        #expect(RemoteWorktreePoll.classify(old: entries, new: entries) == nil)
    }

    @Test func branchSwitchYieldsLabelUpdateWithoutTopology() {
        let old = RemoteWorktreePoll.parse(porcelain: porcelain)
        var new = old
        new[1] = RemoteWorktreePollEntry(path: new[1].path, head: new[1].head, branch: "refs/heads/other")
        let delta = RemoteWorktreePoll.classify(old: old, new: new)
        #expect(delta == RemoteWorktreePollDelta(
            branchLabelsByPath: ["/srv/wt/feature": "other"],
            headMoved: false,
            topologyChanged: false
        ))
    }

    @Test func detachedYieldsDetachedLabel() {
        let old = RemoteWorktreePoll.parse(porcelain: porcelain)
        var new = old
        new[0] = RemoteWorktreePollEntry(path: new[0].path, head: new[0].head, branch: nil)
        let delta = RemoteWorktreePoll.classify(old: old, new: new)
        #expect(delta?.branchLabelsByPath["/srv/repo"] == "(detached)")
    }

    @Test func newCommitYieldsTopologyChange() {
        let old = RemoteWorktreePoll.parse(porcelain: porcelain)
        var new = old
        new[0] = RemoteWorktreePollEntry(
            path: new[0].path,
            head: "9999999999999999999999999999999999999999",
            branch: new[0].branch
        )
        let delta = RemoteWorktreePoll.classify(old: old, new: new)
        #expect(delta == RemoteWorktreePollDelta(
            branchLabelsByPath: [:],
            headMoved: true,
            topologyChanged: true
        ))
    }

    @Test func addedOrRemovedWorktreeYieldsTopologyChange() {
        let old = RemoteWorktreePoll.parse(porcelain: porcelain)
        let new = Array(old.dropLast())
        let delta = RemoteWorktreePoll.classify(old: old, new: new)
        #expect(delta?.topologyChanged == true)
    }

    @Test func tickGateCoalescesOverlappingTicks() {
        var gate = RemoteProjectGitTickGate()
        let firstBegin = gate.beginOrMarkPending()
        let overlappingBegin = gate.beginOrMarkPending()
        let firstFinishNeedsFollowUp = gate.finishTick()
        let secondFinishReleases = gate.finishTick()
        let secondBegin = gate.beginOrMarkPending()
        let finalFinishReleases = gate.finishTick()

        #expect(firstBegin)
        #expect(!overlappingBegin)
        #expect(firstFinishNeedsFollowUp)
        #expect(!secondFinishReleases)
        #expect(secondBegin)
        #expect(!finalFinishReleases)
    }

    @Test func watcherEventsDispatchSharedRefsWhenWorktreesAreUnchanged() {
        let entries = RemoteWorktreePoll.parse(porcelain: porcelain)
        let events = RemoteProjectGitWatcher.events(old: entries, new: entries, sharedRefsMoved: true)
        #expect(events == RemoteProjectGitWatcherEvents(
            branchLabelsByPath: [:],
            revisionChanged: true,
            topologyChanged: false
        ))
    }

    @Test func helperGitEventsOnlyRequestAuthoritativeTick() {
        let event = RemoteHelperWatchEvent(
            subscriptionId: "sub",
            root: "/srv/repo",
            kind: .git,
            paths: ["/srv/repo/.git/index"]
        )

        #expect(RemoteProjectGitWatcher.helperEventAction(for: event) == RemoteProjectGitWatcherHelperEventAction(
            runTick: true,
            bumpRevisionImmediately: false
        ))
    }

    @Test func watcherEventsMergeHeadAndSharedRefChanges() {
        let old = RemoteWorktreePoll.parse(porcelain: porcelain)
        var new = old
        new[1] = RemoteWorktreePollEntry(
            path: new[1].path,
            head: "9999999999999999999999999999999999999999",
            branch: new[1].branch
        )
        let events = RemoteProjectGitWatcher.events(old: old, new: new, sharedRefsMoved: true)
        #expect(events == RemoteProjectGitWatcherEvents(
            branchLabelsByPath: [:],
            revisionChanged: true,
            topologyChanged: true
        ))
    }

    @Test func sharedRefsSignatureIncludesPseudoRefs() {
        let signature = RemoteProjectGitWatcher.sharedRefsSignature(
            showRefOutput: "abc refs/heads/main\n",
            pseudoRefCommits: [
                "/repo:FETCH_HEAD": "fetch-sha",
                "/repo/worktrees/feat:REBASE_HEAD": "rebase-sha",
            ]
        )

        #expect(signature.contains("abc refs/heads/main"))
        #expect(signature.contains("/repo:FETCH_HEAD:fetch-sha"))
        #expect(signature.contains("/repo/worktrees/feat:REBASE_HEAD:rebase-sha"))
    }

    @Test func sharedRefsSignatureIncludesSortedPrivateWorktreeRefs() {
        let privateRefs = RemoteProjectGitWatcher.privateRefsSignature(pathOutputs: [
            "/srv/repo": "bbb refs/worktree/follow\n",
            "/srv/wt/feature": "aaa refs/rewritten/main\nccc refs/bisect/good-abc\n",
        ])
        let signature = RemoteProjectGitWatcher.sharedRefsSignature(
            showRefOutput: "abc refs/heads/main\n",
            privateRefsOutput: privateRefs,
            pseudoRefCommits: [:]
        )

        #expect(signature.contains("private-refs:/srv/repo:bbb refs/worktree/follow"))
        #expect(signature.contains("/srv/wt/feature:aaa refs/rewritten/main"))
        #expect(signature.contains("/srv/wt/feature:ccc refs/bisect/good-abc"))
    }

    @Test func sharedRefsSignatureIncludesCustomTopLevelRefs() {
        let topLevelRefs = RemoteProjectGitWatcher.topLevelRefsSignature(pathOutputs: [
            "/srv/repo": "FOO ref: refs/heads/main\nDIRECT 0123456789abcdef0123456789abcdef01234567\nshallow entries=1;sha=abc\ninfo/grafts entries=1;sha=def\nobjects/info/alternates entries=1;sha=ghi\n",
            "/srv/wt/feature": "BAR ref: refs/heads/feature\n",
        ])
        let signature = RemoteProjectGitWatcher.sharedRefsSignature(
            showRefOutput: "abc refs/heads/main\n",
            customTopLevelRefsOutput: topLevelRefs,
            pseudoRefCommits: [:]
        )

        #expect(signature.contains("top-level-refs:/srv/repo:DIRECT 0123456789abcdef0123456789abcdef01234567"))
        #expect(signature.contains("/srv/repo:FOO ref: refs/heads/main"))
        #expect(signature.contains("/srv/repo:shallow entries=1;sha=abc"))
        #expect(signature.contains("/srv/repo:info/grafts entries=1;sha=def"))
        #expect(signature.contains("/srv/repo:objects/info/alternates entries=1;sha=ghi"))
        #expect(signature.contains("/srv/wt/feature:BAR ref: refs/heads/feature"))
    }

    @Test func customTopLevelRefsCommandScansAbsoluteGitDir() {
        let command = RemoteProjectGitWatcher.customTopLevelRefsCommand()
        #expect(command.contains("git rev-parse --absolute-git-dir"))
        #expect(command.contains("ref: refs/"))
        #expect(command.contains("0-9a-fA-F"))
        #expect(command.contains("packed-refs"))
        #expect(command.contains("shallow entries"))
        #expect(command.contains("info/grafts entries"))
        #expect(command.contains("objects/info/alternates entries"))
    }

    @Test func sharedRefsSignatureIncludesOrderedUpstreamConfig() {
        let config = """
        branch.feature.merge refs/heads/main
        branch.feature.remote origin
        remote.origin.fetch +refs/heads/main:refs/remotes/origin/main
        """
        let reordered = """
        remote.origin.fetch +refs/heads/main:refs/remotes/origin/main
        branch.feature.remote origin
        branch.feature.merge refs/heads/main
        """
        let changed = """
        branch.feature.merge refs/heads/next
        branch.feature.remote origin
        remote.origin.fetch +refs/heads/main:refs/remotes/origin/main
        """
        let fetchChanged = """
        branch.feature.merge refs/heads/main
        branch.feature.remote origin
        remote.origin.fetch +refs/heads/main:refs/remotes/fork/main
        """
        let duplicateOrderChanged = """
        branch.feature.merge refs/heads/main
        branch.feature.remote fork
        branch.feature.remote origin
        remote.origin.fetch +refs/heads/main:refs/remotes/origin/main
        """
        let pushChanged = """
        branch.feature.merge refs/heads/main
        branch.feature.pushremote fork
        branch.feature.remote origin
        remote.origin.fetch +refs/heads/main:refs/remotes/origin/main
        push.default current
        remote.fork.push refs/heads/feature:refs/heads/feature
        remote.pushdefault origin
        """

        let first = RemoteProjectGitWatcher.sharedRefsSignature(
            showRefOutput: "abc refs/heads/main\n",
            revisionConfigOutput: RemoteProjectGitWatcher.revisionConfigSignature(pathOutputs: ["/srv/repo": config]),
            pseudoRefCommits: [:]
        )
        let same = RemoteProjectGitWatcher.sharedRefsSignature(
            showRefOutput: "abc refs/heads/main\n",
            revisionConfigOutput: RemoteProjectGitWatcher.revisionConfigSignature(pathOutputs: ["/srv/repo": reordered]),
            pseudoRefCommits: [:]
        )
        let second = RemoteProjectGitWatcher.sharedRefsSignature(
            showRefOutput: "abc refs/heads/main\n",
            revisionConfigOutput: RemoteProjectGitWatcher.revisionConfigSignature(pathOutputs: ["/srv/repo": changed]),
            pseudoRefCommits: [:]
        )
        let pushed = RemoteProjectGitWatcher.sharedRefsSignature(
            showRefOutput: "abc refs/heads/main\n",
            revisionConfigOutput: RemoteProjectGitWatcher.revisionConfigSignature(pathOutputs: ["/srv/repo": pushChanged]),
            pseudoRefCommits: [:]
        )
        let fetched = RemoteProjectGitWatcher.sharedRefsSignature(
            showRefOutput: "abc refs/heads/main\n",
            revisionConfigOutput: RemoteProjectGitWatcher.revisionConfigSignature(pathOutputs: ["/srv/repo": fetchChanged]),
            pseudoRefCommits: [:]
        )
        let duplicateReordered = RemoteProjectGitWatcher.sharedRefsSignature(
            showRefOutput: "abc refs/heads/main\n",
            revisionConfigOutput: RemoteProjectGitWatcher.revisionConfigSignature(pathOutputs: ["/srv/repo": duplicateOrderChanged]),
            pseudoRefCommits: [:]
        )

        #expect(first != same)
        #expect(first != second)
        #expect(first != pushed)
        #expect(first != fetched)
        #expect(first != duplicateReordered)
        #expect(first.contains("config:/srv/repo:branch.feature.merge refs/heads/main"))
        #expect(first.contains("remote.origin.fetch +refs/heads/main:refs/remotes/origin/main"))
        #expect(pushed.contains("branch.feature.pushremote fork"))
        #expect(pushed.contains("remote.fork.push refs/heads/feature:refs/heads/feature"))
        #expect(pushed.contains("remote.pushdefault origin"))
        #expect(pushed.contains("push.default current"))
    }

    @Test func revisionConfigPatternMatchesGitCanonicalRevisionKeys() throws {
        let regex = try Regex(RemoteProjectGitWatcher.revisionConfigPattern)
        #expect("branch.feature.pushremote".wholeMatch(of: regex) != nil)
        #expect("remote.pushdefault".wholeMatch(of: regex) != nil)
        #expect("remote.origin.fetch".wholeMatch(of: regex) != nil)
        #expect("remote.fork.push".wholeMatch(of: regex) != nil)
        #expect("branch.feature.pushRemote".wholeMatch(of: regex) == nil)
        #expect("remote.pushDefault".wholeMatch(of: regex) == nil)
    }

    @Test func revisionConfigSignatureQualifiesEachWorktreePath() {
        let main = """
        branch.feature.merge refs/heads/main
        branch.feature.remote origin
        """
        let linked = """
        branch.feature.merge refs/heads/linked
        branch.feature.remote origin
        """

        let signature = RemoteProjectGitWatcher.revisionConfigSignature(pathOutputs: [
            "/srv/repo": main,
            "/srv/repo-linked": linked,
        ])

        #expect(signature.contains("/srv/repo:branch.feature.merge refs/heads/main"))
        #expect(signature.contains("/srv/repo-linked:branch.feature.merge refs/heads/linked"))
    }

    @Test func sharedRefsSignatureIncludesCompleteReflogSignature() {
        let full = RemoteProjectGitWatcher.reflogSignature(from: "abc HEAD@{0}\ndef HEAD@{1}\n")
        let shortened = RemoteProjectGitWatcher.reflogSignature(from: "abc HEAD@{0}\n")
        let first = RemoteProjectGitWatcher.sharedRefsSignature(
            showRefOutput: "abc refs/heads/main\n",
            reflogSignature: full,
            pseudoRefCommits: [:]
        )
        let second = RemoteProjectGitWatcher.sharedRefsSignature(
            showRefOutput: "abc refs/heads/main\n",
            reflogSignature: shortened,
            pseudoRefCommits: [:]
        )

        #expect(first != second)
        #expect(first.contains("reflog:entries=2;sha="))
    }

    @Test func reflogDigestCommandCoversCompleteReflog() {
        let command = RemoteProjectGitWatcher.reflogDigestCommand()
        #expect(command.contains("git reflog show --all --format='%H %gD'"))
        #expect(!command.contains("--max-count"))
        #expect(command.contains("shasum -a 256") || command.contains("sha256sum"))
    }
}
