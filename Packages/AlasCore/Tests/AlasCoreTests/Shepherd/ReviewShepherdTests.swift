import Foundation
import Testing
@testable import AlasCore
@testable import AlasHostCore

private typealias F = ShepherdFixtures

@MainActor
struct ReviewShepherdTests {
    private final class MemoryStore: PersistenceStoreProtocol {
        var files: [URL: Data] = [:]

        func write<T: Encodable>(_ value: T, to url: URL) throws {
            files[url] = try JSONEncoder().encode(value)
        }

        func readIfExists<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
            guard let data = files[url] else { return nil }
            return try JSONDecoder().decode(T.self, from: data)
        }
    }

    /// Serves one open request on the worktree's branch.
    private struct FakeProvider: CodeHostProvider {
        let request: ReviewRequest
        var kind: CodeHostKind { .github }

        func isAvailable(cwd: URL) async -> Bool { true }
        func isAuthenticated(remote: CodeHostRemote, cwd: URL) async -> Bool { true }
        func currentReviewRequest(
            remote: CodeHostRemote, branch: String, headOwner: String?, baseBranch: String, cwd: URL
        ) async throws -> ReviewRequest? {
            request
        }
        func createReviewRequest(
            remote: CodeHostRemote, branch: String, headOwner: String?, baseBranch: String,
            title: String, body: String, isDraft: Bool, cwd: URL
        ) async throws -> URL {
            throw CodeHostProviderError.unsupportedProvider(kind)
        }
        func checks(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewCheck] {
            request.checks
        }
        func rerunFailedChecks(
            remote: CodeHostRemote, branch: String, headSHA: String, request: ReviewRequest?, cwd: URL
        ) async throws {}
    }

    /// Holds a prompt delivery until the test releases it.
    private final class DeliveryGate {
        var release: CheckedContinuation<Void, Never>?
        var delivered: [String] = []
    }

    private struct RulesUnreadable: Error {}

    /// A shepherd watching `request`, a branch pushed at its head, owned by an
    /// idle session.
    private func makeShepherd(
        request: ReviewRequest,
        deliverPrompt: @escaping @MainActor (String, @escaping @MainActor () -> Bool) async -> ReviewShepherd.Delivery,
        rules: @escaping @MainActor () throws -> ShepherdRules = { .none }
    ) -> ReviewShepherd {
        let local = ReviewLoopLocalState(
            branchName: "fix-login", headSHA: F.head, baseBranch: "main",
            hasWorkingTreeChanges: false, hasStagedChanges: false, aheadCommitCount: 1,
            hasUpstream: true, upstreamRemoteName: "origin", upstreamBranchName: "fix-login",
            needsPush: false
        )
        let shepherd = ReviewShepherd(
            store: MemoryStore(),
            fileURL: URL(fileURLWithPath: "/memory/review-shepherds.json"),
            providerRegistry: CodeHostProviderRegistry(providers: [.github: FakeProvider(request: request)]),
            localProbe: ReviewLoopLocalProbe { _, _ in
                (local: local, remotes: [GitRemote(name: "origin", url: "https://github.com/acme/app.git")])
            },
            now: { F.now }
        )
        shepherd.effects = ReviewShepherd.Effects(
            worktreeContext: { worktreeID in
                ReviewShepherd.WorktreeContext(
                    worktreeID: worktreeID, projectID: "project-1",
                    path: URL(fileURLWithPath: "/tmp/\(worktreeID)"), baseBranch: "main", isEligible: true
                )
            },
            sessionState: { _, _ in .idle },
            deliverPrompt: { _, _, prompt, isStillWanted in await deliverPrompt(prompt.text, isStillWanted) },
            rules: { _ in try rules() },
            notify: { _ in },
            refreshPaneIfCached: { _ in },
            archiveWorktreeIfAllowed: { _, _, _ in .declined }
        )
        return shepherd
    }

    @Test func turnEndingWhileTheFixPromptIsDeliveredKeepsTheFix() async throws {
        let request = F.request(threads: [F.trustedThread])
        let gate = DeliveryGate()
        let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
        let shepherd = makeShepherd(request: request) { text, isStillWanted in
            await withCheckedContinuation { continuation in
                gate.release = continuation
                enteredContinuation.yield()
            }
            guard isStillWanted() else { return .superseded }
            gate.delivered.append(text)
            return .delivered
        }
        let record = await shepherd.bind(
            sessionID: "session-1", worktreeID: "wt-1", request: request, baseBranch: "main",
            autoFix: true, autoMerge: false, contextRules: nil
        )

        let evaluation = Task { await shepherd.evaluateNow(record.id) }
        var iterator = entered.makeAsyncIterator()
        await iterator.next()
        // Another turn of the owner ends while the fix prompt is on its way.
        shepherd.turnCompleted(sessionID: "session-1")
        gate.release?.resume()
        await evaluation.value

        #expect(gate.delivered.count == 1)
        #expect(shepherd.records[record.id]?.phase == .fixing(dispatchedAt: F.now))
    }

    @Test func unreadableRulesHoldEveryDecision() async {
        let request = F.request(threads: [F.trustedThread])
        var delivered: [String] = []
        let shepherd = makeShepherd(request: request, deliverPrompt: { text, _ in
            delivered.append(text)
            return .delivered
        }, rules: { throw RulesUnreadable() })
        let record = await shepherd.bind(
            sessionID: "session-1", worktreeID: "wt-1", request: request, baseBranch: "main",
            autoFix: true, autoMerge: true, contextRules: nil
        )

        await shepherd.evaluateNow(record.id)

        #expect(delivered.isEmpty)
        #expect(shepherd.records[record.id]?.phase == .watching)
    }
}
