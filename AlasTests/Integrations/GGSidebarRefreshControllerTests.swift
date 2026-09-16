import Foundation
import Testing
@testable import Alas

@MainActor
struct GGSidebarRefreshControllerTests {
    private func project(_ id: String) -> GGSidebarRefreshController.Project {
        .init(id: id, path: "/\(id)", worktrees: [.init(path: "/\(id)/wt", stackName: id)])
    }

    private func stack(_ name: String, count: Int = 1) -> GGStack {
        GGStack(name: name, base: "main", totalCommits: count, syncedCommits: 0, currentPosition: nil, behindBase: nil,
                entries: (0..<count).map { GGStackEntry(position: $0 + 1, sha: "sha\($0)", title: "Local") })
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            guard Date() < deadline else { throw Timeout.elapsed }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private enum Timeout: Error { case elapsed }

    @Test func detachedStackLoadsLocallyButAmbiguousOwnerIsRejected() async throws {
        let summaries = GGStackSummaryStore()
        let inbox = GGInboxStore()
        var remoteCalls = 0
        let controller = GGSidebarRefreshController(summaries: summaries, inbox: inbox, debounce: .zero, load: { _ in
            stack("actual")
        }, refreshInbox: { _, _ in remoteCalls += 1 })
        var target = GGSidebarRefreshController.Project(id: "p", path: "/p", worktrees: [.init(path: "/p/wt", stackName: nil)])
        controller.refresh(projects: [target])
        try await waitUntil { remoteCalls == 1 }
        #expect(summaries.summary(forPath: "/p/wt", inbox: inbox)?.total == 1)
        target.ambiguousStackNames = ["actual"]
        controller.refresh(projects: [target])
        try await waitUntil { remoteCalls == 2 }
        #expect(summaries.summary(forPath: "/p/wt", inbox: inbox) == nil)
    }

    @Test func boundsProjectsAndCoalescesAttention() async throws {
        let summaries = GGStackSummaryStore()
        let inbox = GGInboxStore()
        var gates: [String: CheckedContinuation<GGStack?, Never>] = [:]
        var calls: [String] = []
        var refreshed: [String] = []
        let controller = GGSidebarRefreshController(summaries: summaries, inbox: inbox, debounce: .zero, load: { path in
            calls.append(path)
            return await withCheckedContinuation { gates[path] = $0 }
        }, refreshInbox: { id, _ in refreshed.append(id) })
        let projects = [project("a"), project("b"), project("c")]
        controller.refresh(projects: projects)
        try await waitUntil { gates.count == 2 }
        for _ in 0..<10 { controller.refresh(projects: projects) }
        #expect(calls.count == 2)
        gates.removeValue(forKey: "/a/wt")?.resume(returning: stack("a"))
        try await waitUntil { gates["/c/wt"] != nil }
        gates.removeValue(forKey: "/b/wt")?.resume(returning: stack("b"))
        gates.removeValue(forKey: "/c/wt")?.resume(returning: stack("c"))
        try await waitUntil { refreshed.count == 3 }
        controller.refresh(projects: projects)
        #expect(calls.count == 3)
        #expect(summaries.summary(forPath: "/a/wt", inbox: inbox) == .init(merged: 0, total: 1))
    }

    @Test func invalidationFencesOldLocalResultAndQueuesOneFreshPass() async throws {
        let summaries = GGStackSummaryStore()
        let inbox = GGInboxStore()
        var gate: CheckedContinuation<GGStack?, Never>?
        var calls = 0
        var remoteCalls = 0
        let controller = GGSidebarRefreshController(summaries: summaries, inbox: inbox, debounce: .zero, load: { _ in
            calls += 1
            return await withCheckedContinuation { gate = $0 }
        }, refreshInbox: { _, _ in remoteCalls += 1 })
        controller.refresh(projects: [project("a")])
        try await waitUntil { gate != nil }
        inbox.invalidate(projectId: "a")
        inbox.invalidate(projectId: "a")
        let old = gate
        gate = nil
        old?.resume(returning: stack("a", count: 9))
        try await waitUntil { calls == 2 && gate != nil }
        #expect(summaries.summary(forPath: "/a/wt", inbox: inbox) == nil)
        #expect(remoteCalls == 0)
        gate?.resume(returning: stack("a", count: 2))
        gate = nil
        try await waitUntil { remoteCalls == 1 }
        #expect(summaries.summary(forPath: "/a/wt", inbox: inbox)?.total == 2)
    }

    @Test func removalPreventsLatePublicationAndNetworkWork() async throws {
        let summaries = GGStackSummaryStore()
        let inbox = GGInboxStore()
        var gate: CheckedContinuation<GGStack?, Never>?
        var returned = false
        var remoteCalls = 0
        let controller = GGSidebarRefreshController(summaries: summaries, inbox: inbox, debounce: .zero, load: { _ in
            let result = await withCheckedContinuation { gate = $0 }
            returned = true
            return result
        }, refreshInbox: { _, _ in remoteCalls += 1 })
        controller.refresh(projects: [project("a")])
        try await waitUntil { gate != nil }
        controller.refresh(projects: [])
        gate?.resume(returning: stack("a"))
        try await waitUntil { returned }
        #expect(summaries.summary(forPath: "/a/wt", inbox: inbox) == nil)
        #expect(remoteCalls == 0)
    }

    @Test func failureRetainsInventoryAndAttentionRetriesAfterFreshnessWindow() async throws {
        let summaries = GGStackSummaryStore()
        let inbox = GGInboxStore()
        var time = Date(timeIntervalSince1970: 1000)
        var calls = 0
        var remoteCalls = 0
        let controller = GGSidebarRefreshController(summaries: summaries, inbox: inbox, debounce: .zero, now: { time }, load: { _ in
            calls += 1
            if calls > 1 { throw Timeout.elapsed }
            return stack("a", count: 3)
        }, refreshInbox: { _, _ in remoteCalls += 1 })
        controller.refresh(projects: [project("a")])
        try await waitUntil { remoteCalls == 1 }
        controller.refresh(projects: [project("a")])
        #expect(calls == 1)
        time = time.addingTimeInterval(121)
        controller.refresh(projects: [project("a")])
        try await waitUntil { remoteCalls == 2 }
        #expect(calls == 2)
        #expect(summaries.summary(forPath: "/a/wt", inbox: inbox)?.total == 3)
    }
}
