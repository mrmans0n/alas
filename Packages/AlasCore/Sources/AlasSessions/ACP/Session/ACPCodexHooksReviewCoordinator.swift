import Foundation
import AlasFoundation
import AlasACP

@MainActor
public final class ACPCodexHooksReviewCoordinator: ChangeTracking {
    public struct Context: Equatable, Sendable {
        public let host: String
        public let cwd: String
        public init(host: String, cwd: String) {
            self.host = host
            self.cwd = cwd
        }
    }
    public struct Presentation: Equatable, Sendable, Identifiable {
        public let id: UUID
        public let context: Context
        public let snapshot: ACPCodexHooksList?
        public let isBusy: Bool
        public let error: String?
    }
    public typealias List = @MainActor @Sendable () async throws -> ACPCodexHooksList
    public typealias Trust = @MainActor @Sendable (String, [ACPCodexHookIdentity]) async throws -> Bool
    nonisolated(unsafe) public let willChange = ChangeSignal<Void>()
    public let context: Context
    @Tracked public private(set) var presentation: Presentation?
    @Tracked public private(set) var selection: Set<ACPCodexHookIdentity> = []
    public private(set) var reviewToken: String?
    private let list: List
    private let trust: Trust
    private var generation = 0
    private var valid = true
    private var waiter: CheckedContinuation<String?, Never>?
    private var waitID: UUID?

    public init(context: Context, list: @escaping List, trust: @escaping Trust) {
        self.context = context
        self.list = list
        self.trust = trust
    }

    /// Suspends startup until a valid review is continued or this attempt is invalidated.
    public func review() async -> String? {
        guard valid, !Task.isCancelled, waiter == nil else { return nil }
        let requestID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard valid, !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                waiter = continuation
                waitID = requestID
                Task { await self.refresh() }
            }
        } onCancel: { Task { @MainActor [weak self] in
            guard let self, self.waitID == requestID else { return }
            self.invalidate()
        } }
    }

    public func setSelected(_ identity: ACPCodexHookIdentity, selected: Bool, presentationID: UUID? = nil) {
        guard actionable(presentationID), let snapshot = presentation?.snapshot,
              snapshot.isUnique(identity), snapshot.hooks.contains(where: { $0.identity == identity && $0.canTrust }) else { return }
        if selected { selection.insert(identity) } else { selection.remove(identity) }
    }

    public func refresh(presentationID: UUID? = nil) async {
        guard valid, presentationID == nil || presentation?.id == presentationID,
              presentation?.isBusy != true else { return }
        generation += 1
        let current = generation
        reviewToken = nil
        let id = UUID()
        presentation = .init(id: id, context: context, snapshot: nil, isBusy: true, error: nil)
        do {
            let snapshot = try await list()
            guard valid, generation == current else { return }
            guard sameDirectory(snapshot.cwd) else { throw ReviewFailure("The hook review belongs to a different working directory.") }
            apply(snapshot, id: id, error: nil)
            if !snapshot.requiresReview { finish(snapshot.reviewToken) }
        } catch {
            guard valid, generation == current else { return }
            selection = []
            presentation = .init(id: id, context: context, snapshot: nil, isBusy: false, error: message(error))
        }
    }

    public func trustSelectedAndContinue(presentationID: UUID? = nil) async {
        guard actionable(presentationID), let snapshot = presentation?.snapshot, !selection.isEmpty else { return }
        let pairs = snapshot.hooks.filter { selection.contains($0.identity) && $0.canTrust && snapshot.isUnique($0.identity) }.map(\.identity)
        guard pairs.count == selection.count else { return }
        let current = generation
        let id = presentation!.id
        presentation = .init(id: id, context: context, snapshot: snapshot, isBusy: true, error: nil)
        var failure: String?
        do {
            if try await trust(snapshot.reviewToken, pairs) == false { failure = "Codex did not confirm the selected hooks as trusted." }
        } catch { failure = message(error) }
        guard valid, generation == current else { return }
        do {
            let fresh = try await list()
            guard valid, generation == current else { return }
            guard sameDirectory(fresh.cwd) else { throw ReviewFailure("The hook review belongs to a different working directory.") }
            let accepted = pairs.allSatisfy { identity in
                fresh.isUnique(identity) && fresh.hooks.contains { $0.identity == identity && $0.isKnown && $0.trustStatus == "trusted" }
            }
            // Trust-state updates preserve the adapter token; a different token describes an unseen snapshot.
            let sameReview = fresh.reviewToken == snapshot.reviewToken
            if failure == nil && accepted && sameReview {
                apply(fresh, id: id, error: nil)
                finish(fresh.reviewToken)
            } else {
                let readbackError = sameReview
                    ? "Selected hooks changed or could not be verified. Review them again."
                    : "The hook configuration changed. Review it again before continuing."
                apply(fresh, id: UUID(), error: failure ?? readbackError)
            }
        } catch {
            guard valid, generation == current else { return }
            reviewToken = nil
            selection = []
            presentation = .init(id: id, context: context, snapshot: nil, isBusy: false, error: failure ?? message(error))
        }
    }

    @discardableResult
    public func continueWithoutTrusting(presentationID: UUID? = nil) -> String? {
        guard actionable(presentationID), let snapshot = presentation?.snapshot else { return nil }
        finish(snapshot.reviewToken)
        return snapshot.reviewToken
    }

    public func cancel(presentationID: UUID? = nil) {
        guard presentationID == nil || presentation?.id == presentationID else { return }
        invalidate()
    }
    public func invalidate() {
        valid = false
        generation += 1
        reviewToken = nil
        selection = []
        presentation = nil
        waiter?.resume(returning: nil)
        waiter = nil
        waitID = nil
    }
    private func actionable(_ id: UUID?) -> Bool {
        valid && presentation != nil && presentation?.isBusy == false && (id == nil || presentation?.id == id)
    }
    /// Codex reports the agent-side path: an SSH worktree's real remote path
    /// rather than its `/.alas-remote/<host>/…` id, and a local path with
    /// symlinks resolved.
    private func sameDirectory(_ reported: String) -> Bool {
        ACPSessionBrowserPaths.key(reported, context: context.cwd) == ACPSessionBrowserPaths.key(context.cwd, context: context.cwd)
    }
    private func apply(_ snapshot: ACPCodexHooksList, id: UUID, error: String?) {
        reviewToken = snapshot.reviewToken
        selection = selection.filter { identity in snapshot.isUnique(identity) && snapshot.hooks.contains { $0.identity == identity && $0.canTrust } }
        presentation = .init(id: id, context: context, snapshot: snapshot, isBusy: false, error: error)
    }
    private func finish(_ token: String) {
        reviewToken = token
        presentation = nil
        selection = []
        waiter?.resume(returning: token)
        waiter = nil
        waitID = nil
    }
    private func message(_ error: any Error) -> String {
        if let rpc = error as? JSONRPCError { return rpc.message }
        return error.localizedDescription
    }
    private struct ReviewFailure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
