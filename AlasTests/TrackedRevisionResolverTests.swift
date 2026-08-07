import Foundation
import Testing
@testable import Alas

struct TrackedRevisionResolverTests {
    private let worktree = URL(fileURLWithPath: "/tmp/wt")

    private func stack(entries: [GGStackEntry]) -> GGStack {
        GGStack(
            name: "my-feature",
            base: "main",
            totalCommits: entries.count,
            syncedCommits: 0,
            currentPosition: 1,
            behindBase: 0,
            entries: entries
        )
    }

    private func resolver(
        stack: GGStack?,
        shas: [String: String] = [:],
        branch: String = "nacho/my-feature"
    ) -> TrackedRevisionResolver {
        TrackedRevisionResolver(
            resolve: { _, ref in
                if ref == "HEAD" { return "head000" }
                if let full = shas[ref] { return full }
                return ref
            },
            branch: { _ in branch },
            stack: { _ in stack }
        )
    }

    @Test func expandsTheAbbreviatedShaGGReports() async throws {
        let resolver = resolver(
            stack: stack(entries: [
                GGStackEntry(position: 1, sha: "abc1234", title: "first", ggId: "c-abc1234"),
                GGStackEntry(position: 2, sha: "def5678", title: "second", ggId: "c-def5678"),
            ]),
            shas: ["def5678": "def5678000000000000000000000000000000000"]
        )

        let candidate = try await resolver.resolve(
            at: worktree,
            target: .stackEntry(ggID: "c-def5678")
        )

        #expect(candidate.sha == "def5678000000000000000000000000000000000")
        #expect(candidate.branch == "nacho/my-feature")
        #expect(candidate.headSHA == "head000")
    }

    @Test func missingEntryThrowsStackEntryNotFound() async {
        let resolver = resolver(
            stack: stack(entries: [
                GGStackEntry(position: 1, sha: "abc1234", title: "first", ggId: "c-abc1234"),
            ])
        )

        await #expect(throws: TrackedRevisionResolverError.stackEntryNotFound("c-gone")) {
            try await resolver.resolve(at: worktree, target: .stackEntry(ggID: "c-gone"))
        }
    }

    @Test func offStackBranchThrowsStackEntryNotFound() async {
        let resolver = resolver(stack: nil)

        await #expect(throws: TrackedRevisionResolverError.stackEntryNotFound("c-abc1234")) {
            try await resolver.resolve(at: worktree, target: .stackEntry(ggID: "c-abc1234"))
        }
    }

    @Test func entriesWithoutAGGIDAreNeverMatched() async {
        let resolver = resolver(
            stack: stack(entries: [GGStackEntry(position: 1, sha: "abc1234", title: "unstacked")])
        )

        await #expect(throws: TrackedRevisionResolverError.stackEntryNotFound("abc1234")) {
            try await resolver.resolve(at: worktree, target: .stackEntry(ggID: "abc1234"))
        }
    }

    @Test func expressionTargetsStillResolveThroughGit() async throws {
        let resolver = resolver(stack: nil, shas: ["head000~2": "older00"])

        let candidate = try await resolver.resolve(at: worktree, target: .expression("HEAD~2"))

        #expect(candidate.sha == "older00")
        #expect(candidate.headSHA == "head000")
    }
}
