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

    @Test func sharedRefsSignatureIncludesSortedUpstreamConfig() {
        let config = """
        branch.feature.merge refs/heads/main
        branch.feature.remote origin
        """
        let reordered = """
        branch.feature.remote origin
        branch.feature.merge refs/heads/main
        """
        let changed = """
        branch.feature.merge refs/heads/next
        branch.feature.remote origin
        """
        let pushChanged = """
        branch.feature.merge refs/heads/main
        branch.feature.pushRemote fork
        branch.feature.remote origin
        push.default current
        remote.pushDefault origin
        """

        let first = RemoteProjectGitWatcher.sharedRefsSignature(
            showRefOutput: "abc refs/heads/main\n",
            upstreamConfigOutput: RemoteProjectGitWatcher.upstreamConfigSignature(from: config),
            pseudoRefCommits: [:]
        )
        let same = RemoteProjectGitWatcher.sharedRefsSignature(
            showRefOutput: "abc refs/heads/main\n",
            upstreamConfigOutput: RemoteProjectGitWatcher.upstreamConfigSignature(from: reordered),
            pseudoRefCommits: [:]
        )
        let second = RemoteProjectGitWatcher.sharedRefsSignature(
            showRefOutput: "abc refs/heads/main\n",
            upstreamConfigOutput: RemoteProjectGitWatcher.upstreamConfigSignature(from: changed),
            pseudoRefCommits: [:]
        )
        let pushed = RemoteProjectGitWatcher.sharedRefsSignature(
            showRefOutput: "abc refs/heads/main\n",
            upstreamConfigOutput: RemoteProjectGitWatcher.upstreamConfigSignature(from: pushChanged),
            pseudoRefCommits: [:]
        )

        #expect(first == same)
        #expect(first != second)
        #expect(first != pushed)
        #expect(first.contains("config:branch.feature.merge refs/heads/main"))
        #expect(pushed.contains("branch.feature.pushRemote fork"))
        #expect(pushed.contains("remote.pushDefault origin"))
        #expect(pushed.contains("push.default current"))
    }

    @Test func sharedRefsSignatureIncludesReflogOutput() {
        let first = RemoteProjectGitWatcher.sharedRefsSignature(
            showRefOutput: "abc refs/heads/main\n",
            reflogOutput: "abc HEAD@{0}\ndef HEAD@{1}\n",
            pseudoRefCommits: [:]
        )
        let second = RemoteProjectGitWatcher.sharedRefsSignature(
            showRefOutput: "abc refs/heads/main\n",
            reflogOutput: "abc HEAD@{0}\n",
            pseudoRefCommits: [:]
        )

        #expect(first != second)
        #expect(first.contains("reflog:abc HEAD@{0}"))
        #expect(first.contains("def HEAD@{1}"))
    }
}
