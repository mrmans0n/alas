import Foundation
import Testing
import AlasCore

struct PluginStacksTests {
    @Test(arguments: [GGWorktreeMode.on, .off])
    func verifiedDetachedOwnerRecoversActionsOnlyWhenPolicyPermits(mode: GGWorktreeMode) {
        let detached = GGWorktreeContextResolver.resolve(masterEnabled: true, ggInstalled: true, isRemoteProject: false,
                                                         projectMode: .on, worktreeOverride: mode, isMainWorktree: false,
                                                         repoHasGGConfig: true, branchUsername: "nacho", branch: "HEAD")
        #expect(!detached.isActive)
        #expect(detached.resolvingCurrentStack(named: "verified-stack").isActive == (mode == .on))
        #expect(detached.resolvingCurrentStack(named: nil) == detached)
        #expect(GGWorktreeContext.inactive(reason: .masterDisabled).resolvingCurrentStack(named: "verified-stack") == .inactive(reason: .masterDisabled))
    }

    @Test(arguments: [false, true])
    func startupSettlementKeepsPriorLostRepliesReserved(afterLostReply: Bool) {
        let refusal = RemoteHelperClientError.jsonrpc(JSONRPCError(code: -32055, message: "supervisor spawn failed", data: nil))
        #expect(RemotePluginProcess.requiresStartupReconciliation(refusal, afterLostReply: afterLostReply) == afterLostReply)
        let legacy = RemoteHelperClientError.jsonrpc(JSONRPCError(code: -32050, message: "startup failed", data: nil))
        #expect(RemotePluginProcess.requiresStartupReconciliation(legacy, afterLostReply: afterLostReply))
        #expect(RemotePluginProcess.requiresStartupReconciliation(RemoteHelperClientError.notRunning, afterLostReply: afterLostReply))
    }

    @Test func nonapplicableInventoryRetainsItsExplicitScopeAndKnownReadOnlyStacks() throws {
        let unsupported = try JSONDecoder().decode(StackInventory.self, from: Data(#"{"complete":false,"busy":false,"stacks":[],"applicable":false,"error":"SSH project"}"#.utf8))
        let retained = unsupported.retainingKnownStacks(from: .init(complete: true, busy: false, stacks: [fixture()]))
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(retained)) as? [String: Any])
        #expect(encoded["applicable"] as? Bool == false)
        #expect(retained.stacks.count == 1 && retained.stacks.allSatisfy { !$0.complete && $0.actions.isEmpty })
        let unknown = try JSONDecoder().decode(StackInventory.self, from: Data(#"{"complete":false,"busy":false,"stacks":[],"error":"Read failed"}"#.utf8))
        let unknownJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(unknown)) as? [String: Any])
        #expect(unknownJSON["applicable"] == nil)
    }

    @Test func api18IsAccepted() throws {
        let data = Data(#"{"id":"io.test.stacks","name":"Stacks","version":"1","api":18,"entry":"p.js"}"#.utf8)
        #expect(try PluginManifest.parse(data).api == 18)
    }

    @Test func openPinsEntireOrderedScopeAndLandResolvesTheLastEntry() throws {
        let stack = fixture()
        let request = PluginStackOpenParams(stack: stack.id, fingerprint: stack.fingerprint, action: .land, entry: "a")
        #expect(try request.resolve(in: .init(complete: true, busy: false, stacks: [stack])).entry?.id == "b")
        let through = PluginStackOpenParams(stack: stack.id, fingerprint: stack.fingerprint, action: .landThrough, entry: "a")
        #expect(try through.resolve(in: .init(complete: true, busy: false, stacks: [stack])).entry?.id == "a")
        let changed = fixture(sha: "changed")
        #expect(throws: PluginStackError.self) { try request.resolve(in: .init(complete: true, busy: false, stacks: [changed])) }
    }

    @Test func navigationIsAllowedWhileIncompleteButMutationsAreRefused() throws {
        let stack = fixture()
        let inventory = StackInventory(complete: false, busy: true, stacks: [stack], error: "refresh failed")
        let open = PluginStackOpenParams(stack: stack.id, fingerprint: stack.fingerprint, action: .open)
        #expect(try open.resolve(in: inventory).stack.id == stack.id)
        #expect(throws: PluginStackError.self) {
            try PluginStackOpenParams(stack: stack.id, fingerprint: stack.fingerprint, action: .land).resolve(in: inventory)
        }
    }

    @Test func requestRejectsUnknownEntryAndOversizedIdentity() {
        let stack = fixture()
        #expect(throws: PluginStackError.self) {
            try PluginStackOpenParams(stack: stack.id, fingerprint: stack.fingerprint, action: .landThrough, entry: "foreign")
                .resolve(in: .init(complete: true, busy: false, stacks: [stack]))
        }
        #expect(!PluginStackOpenParams(stack: String(repeating: "x", count: 1025), fingerprint: "f", action: .open).isValid)
    }

    @Test(arguments: [("feature", true), ("feature.part", true), ("功能", true), ("--other", false),
                      ("my feature", false), ("my/feature", false), ("my--feature", false), ("feature.lock", false)])
    func followNeverNormalizesOrInterpretsAnotherStack(name: String, allowed: Bool) {
        #expect(GGService.canFollowExistingStackName(name) == allowed)
    }

    @Test(arguments: [(2, "1,2", true), (3, "1,2", false), (2, "1,1", false), (0, "", false)])
    func partialDirectoryMembershipCannotEnableFollow(count: Int, positions: String, complete: Bool) throws {
        let entries = positions.split(separator: ",").enumerated().map { index, position in
            #"{"position":\#(position),"sha":"sha\#(index)","title":"Unpublished"}"#
        }.joined(separator: ",")
        let json = #"{"version":1,"stacks":[{"name":"feature","base":"main","commit_count":\#(count),"commits":[\#(entries)]}]}"#
        let decoded = try GGStackDirectorySnapshot.decode(fromJSON: Data(json.utf8))
        #expect(decoded.stacks.first?.hasCompleteShape == complete)
    }

    @Test func remoteMembershipIsUnorderedAndCannotInventAChain() throws {
        let decoded = try GGRemoteStackDirectorySnapshot.decode(fromJSON: Data(#"{"version":1,"stacks":[{"name":"far","commit_count":2,"pr_numbers":[9,3]}]}"#.utf8))
        #expect(decoded.stacks.first?.prNumbers == [9, 3])
        #expect(throws: GGServiceError.self) {
            try GGRemoteStackDirectorySnapshot.decode(fromJSON: Data(#"{"version":2,"stacks":[]}"#.utf8))
        }
    }

    @Test func coldLocalStackUsesSavedReviewMembershipWhenRemoteDirectoryExcludesIt() throws {
        let repo = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: repo) }
        let config = repo.appendingPathComponent(".git/gg/config.json")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"stacks":{"feature":{"base":"custom","mrs":{"c-a":9,"c-b":3,"old":9}}}}"#.utf8).write(to: config)
        let directory = try GGStackDirectorySnapshot.decode(fromJSON: Data(#"{"version":1,"stacks":[{"name":"feature","base":"main","commit_count":1,"commits":[{"position":1,"sha":"abc","title":"Unmapped"}]}]}"#.utf8))
        let remote = try GGRemoteStackDirectorySnapshot.decode(fromJSON: Data(#"{"version":1,"stacks":[]}"#.utf8))
        #expect(remote.stacks.isEmpty)
        let membership = try GGConfigReader.stackReviewMembership(repoPath: repo.path)
        let summary = try #require(directory.stacks.first)
        let local = NativeStack(id: "p:feature", name: summary.name, base: summary.base, host: "github.com", repo: "owner/repo",
                                complete: false, entries: summary.commits.map { .init(id: $0.sha, sha: $0.sha, position: $0.position, title: $0.title) }, actions: [.open])
        var inventory = StackInventory(complete: true, busy: false, stacks: [local])
        inventory.includeDiscoveredStack(.init(id: local.id, name: local.name, base: "", host: local.host, repo: local.repo,
                                               complete: false, entries: [], actions: [], reviewNumbers: membership[local.name]))
        let followed = try #require(inventory.stacks.first)
        #expect(followed.reviewNumbers == [3, 9])
        #expect(followed.entries == local.entries && followed.entries.allSatisfy { $0.number == nil })
        #expect(!followed.complete && followed.actions == [.open] && followed.worktree == nil)
        #expect(try PluginStackOpenParams(stack: followed.id, fingerprint: followed.fingerprint, action: .open).resolve(in: inventory).stack == followed)
        for emptyConfig in [#"{}"#, #"{"stacks":{"other":{"mrs":{"c-a":7}}}}"#, #"{"stacks":{"feature":{}}}"#] {
            try Data(emptyConfig.utf8).write(to: config)
            let verified = try GGConfigReader.stackReviewMembership(repoPath: repo.path)
            var empty = StackInventory(complete: true, busy: false, stacks: [local])
            empty.includeDiscoveredStack(.init(id: local.id, name: local.name, base: "", host: local.host, repo: local.repo,
                                                complete: false, entries: [], actions: [], reviewNumbers: verified[local.name] ?? []))
            #expect(empty.stacks.first?.reviewNumbers == [])
        }
        for invalidConfig in [#"{"stacks":{"feature":{"mrs":{"c-a":"9"}}}}"#,
                              #"{"stacks":{"feature":{"mrs":{"c-a":true}}}}"#,
                              #"{"stacks":{"feature":{"mrs":{"c-a":0}}}}"#, #"{"stacks":null}"#,
                              #"{"stacks":{"feature":{"mrs":null}}}"#, "invalid"] {
            try Data(invalidConfig.utf8).write(to: config)
            #expect(throws: GGServiceError.self) { try GGConfigReader.stackReviewMembership(repoPath: repo.path) }
        }
        try FileManager.default.removeItem(at: config)
        #expect(throws: GGServiceError.self) { try GGConfigReader.stackReviewMembership(repoPath: repo.path) }
    }

    @Test func remoteMembershipAssociatesNumberlessLocalStackWithoutInventingEntryMapping() throws {
        let local = NativeStack(id: "p:feature", name: "feature", base: "custom-base", host: "github.com", repo: "owner/repo",
                                complete: false, entries: [.init(id: "sha", sha: "sha", position: 1, title: "Unmapped")], actions: [.open],
                                unavailableActions: ["land": "Refresh the owner worktree"], reviewNumbers: [7])
        let remote = NativeStack(id: local.id, name: local.name, base: "", host: local.host, repo: local.repo,
                                 complete: false, entries: [], actions: [], reviewNumbers: [9, 3])
        var inventory = StackInventory(complete: true, busy: false, stacks: [local])
        inventory.includeDiscoveredStack(remote)
        let merged = try #require(inventory.stacks.first)
        #expect(inventory.stacks.count == 1)
        #expect(merged.reviewNumbers == [3, 7, 9])
        #expect(merged.entries == local.entries && merged.base == local.base && merged.worktree == nil)
        #expect(!merged.complete && merged.actions == [.open] && merged.unavailableActions == local.unavailableActions)
        #expect(merged.fingerprint != local.fingerprint)
        #expect(try PluginStackOpenParams(stack: merged.id, fingerprint: merged.fingerprint, action: .open)
            .resolve(in: inventory).stack == merged)
    }

    @Test func remoteMembershipPreservesAuthoritativeOwnerUnlessItContradictsKnownReviews() throws {
        let owner = fixture()
        func remote(numbers: [Int], host: String? = nil, repo: String? = nil, name: String? = nil) -> NativeStack {
            NativeStack(id: owner.id, name: name ?? owner.name, base: "", host: host ?? owner.host, repo: repo ?? owner.repo,
                        complete: false, entries: [], actions: [], reviewNumbers: numbers)
        }
        var inventory = StackInventory(complete: true, busy: false, stacks: [owner])
        inventory.includeDiscoveredStack(remote(numbers: [2, 1]))
        #expect(inventory.stacks == [owner])
        inventory.includeDiscoveredStack(remote(numbers: [1, 2, 9], host: "other.host"))
        inventory.includeDiscoveredStack(remote(numbers: [1, 2, 9], repo: "other/repo"))
        inventory.includeDiscoveredStack(remote(numbers: [1, 2, 9], name: "other"))
        #expect(inventory.stacks == [owner])
        inventory.includeDiscoveredStack(remote(numbers: [1, 2, 9]))
        let contradicted = try #require(inventory.stacks.first)
        #expect(!contradicted.complete && contradicted.actions == [.open])
        #expect(contradicted.reviewNumbers == [1, 2, 9] && contradicted.entries == owner.entries)
        #expect(contradicted.unavailableActions?["land"] != nil)
    }

    @Test func failedOwnerRefreshKeepsKnownReviewMappingWhenDirectoryReusesTheStackID() throws {
        let known = fixture()
        let directory = NativeStack(id: known.id, name: known.name, base: known.base, host: known.host, repo: known.repo,
                                    worktree: known.worktree, complete: false,
                                    entries: known.entries.map { .init(id: $0.sha, sha: $0.sha, position: $0.position, title: $0.title) }, actions: [.open])
        let failed = StackInventory(complete: false, busy: false, stacks: [directory], error: "Owner refresh failed")
        let retained = failed.retainingKnownStacks(from: .init(complete: true, busy: false, stacks: [known]))
        let stale = try #require(retained.stacks.first)
        #expect(stale.entries == known.entries)
        #expect(stale.actions.isEmpty && !stale.complete && !retained.complete)
    }

    @Test func unavailableContextKeepsKnownIdentityAsReadOnly() throws {
        let known = fixture()
        let unavailable = StackInventory(complete: false, busy: true, stacks: [], error: "Native gg is unavailable")
            .retainingKnownStacks(from: .init(complete: true, busy: false, stacks: [known]))
        let stale = try #require(unavailable.stacks.first)
        #expect(stale.host == known.host && stale.repo == known.repo && stale.entries == known.entries)
        #expect(stale.actions.isEmpty && !stale.complete && unavailable.busy)
        #expect(stale.unavailableActions?["open"] == "Native gg is unavailable")
    }

    @Test func failedContextDoesNotAttachOldReviewsToADifferentRepository() throws {
        let known = fixture()
        let other = NativeStack(id: known.id, name: known.name, base: "main", host: "gitlab.example", repo: "other/repo", complete: false,
                                entries: [.init(id: "other", sha: "other", position: 1, number: 9, title: "Other")], actions: [.open])
        let retained = StackInventory(complete: false, busy: false, stacks: [other], error: "Partial new context")
            .retainingKnownStacks(from: .init(complete: true, busy: false, stacks: [known]))
        #expect(retained.stacks.count == 2)
        #expect(Set(retained.stacks.map(\.id)).count == 2)
        #expect(retained.stacks.first(where: { $0.host == other.host })?.entries.compactMap(\.number) == [9])
        #expect(retained.stacks.first(where: { $0.host == known.host })?.entries.compactMap(\.number) == [1, 2])
        #expect(retained.stacks.allSatisfy { !$0.complete && $0.actions.isEmpty })
    }

    @Test func successfulRefreshCanReplacePreviouslyKnownMembership() {
        let known = fixture()
        let fresh = StackInventory(complete: true, busy: false, stacks: [], fetchedAt: 123)
        #expect(fresh.retainingKnownStacks(from: .init(complete: false, busy: false, stacks: [known])) == fresh)
    }

    private func fixture(sha: String = "head") -> NativeStack {
        NativeStack(id: "stack", name: "test", base: "main", host: "github.com", repo: "owner/repo", worktree: "wt", complete: true,
                    entries: [.init(id: "a", sha: "base", position: 1, number: 1, title: "First"),
                              .init(id: "b", sha: sha, position: 2, number: 2, title: "Second")], actions: NativeStackAction.allCases)
    }
}

@MainActor
struct GGProjectMutationGateTests {
    @Test func reservationExcludesOtherWorktreesAndForeignOwners() throws {
        let gate = GGProjectMutationGate()
        let token = try #require(gate.acquire(project: "p", owner: "plugin:1"))
        #expect(gate.acquire(project: "p", owner: "native:other-worktree") == nil)
        #expect(!gate.release(project: "other", owner: "plugin:1", token: token))
        #expect(!gate.release(project: "p", owner: "plugin:2", token: token))
        #expect(!gate.release(project: "p", owner: "plugin:1", token: "foreign-token"))
        #expect(gate.isBusy(project: "p"))
        #expect(gate.release(project: "p", owner: "plugin:1", token: token))
        let next = try #require(gate.acquire(project: "p", owner: "plugin:1"))
        #expect(!gate.release(project: "p", owner: "plugin:1", token: token))
        #expect(gate.release(project: "p", owner: "plugin:1", token: next))
        #expect(gate.acquire(project: "p", owner: "native:other-worktree") != nil)
    }

    @Test func endingOwnerWaitsForEveryActiveProcessToSettle() throws {
        let gate = GGProjectMutationGate()
        let token = try #require(gate.acquire(project: "p", owner: "plugin:1"))
        let process = try #require(gate.beginProcess(project: "p", owner: "plugin:1"))
        let second = try #require(gate.beginProcess(project: "p", owner: "plugin:1"))
        gate.endOwner(project: "p", owner: "plugin:1")
        #expect(gate.isBusy(project: "p"))
        #expect(gate.acquire(project: "p", owner: "plugin:2") == nil)
        #expect(!gate.release(project: "p", owner: "plugin:1", token: token))
        gate.endProcess(process)
        #expect(gate.isBusy(project: "p"))
        gate.endProcess(second)
        #expect(!gate.isBusy(project: "p"))
    }

    @Test func explicitReleaseAlsoWaitsForProcessSettlement() throws {
        let gate = GGProjectMutationGate()
        let token = try #require(gate.acquire(project: "p", owner: "plugin"))
        let process = try #require(gate.beginProcess(project: "p", owner: "plugin"))
        #expect(gate.release(project: "p", owner: "plugin", token: token))
        #expect(gate.isBusy(project: "p"))
        #expect(gate.beginProcess(project: "p", owner: "plugin") == nil)
        gate.endProcess(process)
        #expect(!gate.isBusy(project: "p"))
    }
}
