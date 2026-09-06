import Foundation
import Observation

struct CommitPublishCreatedCommit: Equatable, Sendable {
    let commitSHA: String
    let comparisonBase: String
    let editorTitle: String
}

@MainActor
@Observable
final class CommitPublishSession {
    private(set) var checkpoint: CommitPublishCheckpoint?
    private var activeRunID: UUID?
    private(set) var lastError: Error?
    private var workflow: CommitPublishWorkflow?
    @ObservationIgnored private var task: Task<Void, Never>?
    private let onCheckpointChange: (CommitPublishCheckpoint?) throws -> Void
    private let onCompletion: (CommitPublishCheckpoint) -> Void

    var activity: CommitPublishActivity { workflow?.activity ?? .idle }
    var isRunning: Bool { activeRunID != nil }

    init(
        checkpoint: CommitPublishCheckpoint?,
        onCheckpointChange: @escaping (CommitPublishCheckpoint?) throws -> Void,
        onCompletion: @escaping (CommitPublishCheckpoint) -> Void
    ) {
        self.checkpoint = checkpoint
        self.onCheckpointChange = onCheckpointChange
        self.onCompletion = onCompletion
    }

    func clearError() { lastError = nil }

    @discardableResult
    func run(
        subject: String,
        body: String,
        amend: Bool,
        operations: CommitPublishOperations,
        prepareDestination: @escaping () async throws -> CommitPublishDestination
    ) -> Task<Void, Never>? {
        guard !isRunning else { return nil }
        let runID = UUID()
        activeRunID = runID
        lastError = nil
        let task = Task { @MainActor in
            defer { finish(runID) }
            let workflow = CommitPublishWorkflow(operations: operations) { [weak self] next in
                guard let self, activeRunID == runID else { return }
                let previous = checkpoint
                if next != nil {
                    checkpoint = next
                }
                try onCheckpointChange(next)
                if next == nil, let previous {
                    checkpoint = nil
                    finish(runID)
                    onCompletion(previous)
                }
            }
            self.workflow = workflow
            do {
                if let checkpoint {
                    await workflow.resume(checkpoint)
                } else {
                    let destination = try await prepareDestination()
                    try Task.checkCancellation()
                    await workflow.start(subject: subject, body: body, amend: amend, destination: destination)
                }
                if activeRunID == runID { lastError = workflow.lastError }
            } catch is CancellationError {
                if activeRunID == runID { lastError = nil }
            } catch {
                if activeRunID == runID { lastError = error }
            }
        }
        self.task = task
        return task
    }

    private func finish(_ runID: UUID) {
        guard activeRunID == runID else { return }
        activeRunID = nil
        task = nil
    }

    func abandonCheckpoint() -> Bool {
        guard !isRunning else { return false }
        checkpoint = nil
        lastError = nil
        workflow = nil
        task = nil
        return true
    }
}

@MainActor
struct CommitPublishOperations {
    var validateReviewTarget: (_ target: CommitPublishReviewTarget) async throws -> Void = { _ in }
    var validateGGTarget: (_ target: GGStackTargetIdentity) async throws -> Void = { _ in }
    var createCommit: (_ subject: String, _ body: String, _ amend: Bool) async throws -> CommitPublishCreatedCommit
    var currentHeadSHA: () async throws -> String
    var remoteBranchContainsCommit: (_ target: CommitPublishReviewTarget, _ commitSHA: String) async throws -> Bool
    var push: (_ target: CommitPublishReviewTarget, _ commitSHA: String) async throws -> Void
    var configureUpstreamTracking: (_ target: CommitPublishReviewTarget) async throws -> Void = { _ in }
    var currentReviewRequestExists: (_ target: CommitPublishReviewTarget) async throws -> Bool
    var createReviewRequest: (_ target: CommitPublishReviewTarget, _ subject: String, _ body: String) async throws -> URL
    var syncGG: () async throws -> Void
    var syncGGForTarget: (_ target: GGStackTargetIdentity) async throws -> Void = { _ in }
    var refreshAfterCompletion: () async -> Void

    static func live(
        worktreePath: URL,
        reviewLoop: ReviewLoopState,
        comparisonBase: String?,
        syncGG: @escaping () async throws -> Void,
        refreshAfterCompletion: @escaping () async -> Void,
        runGit: (([String]) async throws -> ProcessResult)? = nil,
        commit: ((String, String, Bool) async throws -> String)? = nil,
        publicationState: (() async throws -> HeadPublicationState)? = nil,
        containsCommit: ((String, String, String) async throws -> Bool)? = nil
    ) -> Self {
        let git = GitService()
        let run = runGit ?? { try await Process.git($0, cwd: worktreePath) }
        let commit = commit ?? { try await git.commit(worktreePath: worktreePath, subject: $0, body: $1, amend: $2) }
        let publication = publicationState ?? { try await git.headPublicationState(worktreePath: worktreePath) }
        let contains = containsCommit ?? {
            try await git.remoteBranchContainsCommit(worktreePath: worktreePath, remote: $0, branch: $1, commitSHA: $2)
        }
        return Self(
            validateReviewTarget: { target in
                let branchResult = try await run(["symbolic-ref", "--short", "HEAD"])
                let currentBranch = branchResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                guard branchResult.exitCode == 0, currentBranch == target.branch else {
                    throw CommitPublishWorkflowError.branchMismatch(expected: target.branch, actual: currentBranch)
                }
                guard let expectedHeadSHA = target.expectedHeadSHA else { return }
                let headResult = try await run(["rev-parse", "--verify", "HEAD"])
                try GitService.assertSuccess(headResult, op: "Resolve HEAD")
                let currentHeadSHA = headResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                guard currentHeadSHA == expectedHeadSHA else {
                    throw CommitPublishWorkflowError.headMismatch(expected: expectedHeadSHA, actual: currentHeadSHA)
                }
            },
            createCommit: { subject, body, amend in
                if amend, try await publication() == .published {
                    throw CommitPublishWorkflowError.publishedAmend
                }
                let sha = try await commit(subject, body, amend)
                let base: String
                if let comparisonBase {
                    base = comparisonBase
                } else if let parent = try? await run(["rev-parse", "--verify", "\(sha)^"]), parent.exitCode == 0 {
                    base = parent.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    base = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
                }
                return .init(commitSHA: sha, comparisonBase: base, editorTitle: "\(sha.prefix(7)) \(subject)")
            },
            currentHeadSHA: {
                let result = try await run(["rev-parse", "--verify", "HEAD"])
                try GitService.assertSuccess(result, op: "Resolve HEAD")
                return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            },
            remoteBranchContainsCommit: { target, sha in
                let urls = target.capturedPushURLs
                guard !urls.isEmpty else { throw CommitPublishWorkflowError.missingPushDestination }
                for url in urls {
                    if try await !contains(url, target.upstreamBranch ?? target.branch, sha) { return false }
                }
                return true
            },
            push: { target, sha in
                let urls = target.capturedPushURLs
                guard !urls.isEmpty else { throw CommitPublishWorkflowError.missingPushDestination }
                let remote = target.pushRemoteName ?? target.remoteName
                let destination = try await run(["remote", "get-url", "--push", "--all", remote])
                try GitService.assertSuccess(destination, op: "Resolve push destination")
                let currentURLs = destination.stdout.split(whereSeparator: \.isNewline).map(String.init)
                guard currentURLs.sorted() == urls.sorted() else {
                    throw CommitPublishWorkflowError.pushDestinationChanged
                }
                let branch = target.upstreamBranch ?? target.branch
                let ref = "\(sha):refs/heads/\(branch)"
                let result = try await run(["push", "-u", remote, ref])
                guard result.exitCode == 0 else {
                    throw NSError(domain: "CommitPublish", code: Int(result.exitCode),
                        userInfo: [NSLocalizedDescriptionKey: RightPaneState.reviewLoopPushFailureMessage(result)])
                }
            },
            configureUpstreamTracking: { target in
                guard target.upstreamBranch == nil else { return }
                let urls = target.capturedPushURLs
                guard let pushURL = urls.first, !pushURL.isEmpty else {
                    throw CommitPublishWorkflowError.missingPushDestination
                }
                let remote = target.pushRemoteName ?? target.remoteName
                let branch = target.branch
                let destination = try await run(["remote", "get-url", "--push", "--all", remote])
                try GitService.assertSuccess(destination, op: "Resolve push destination")
                let currentURLs = destination.stdout.split(whereSeparator: \.isNewline).map(String.init)
                guard currentURLs.sorted() == urls.sorted() else {
                    throw CommitPublishWorkflowError.pushDestinationChanged
                }
                let branchRef = "refs/heads/\(branch)"
                let trackingRef = "refs/remotes/\(remote)/\(branch)"
                for ref in [branchRef, trackingRef] {
                    let validation = try await run(["check-ref-format", ref])
                    try GitService.assertSuccess(validation, op: "Validate tracking ref")
                }
                let fetch = try await run([
                    "fetch", "--no-tags", "--no-write-fetch-head", "--no-recurse-submodules", "--refmap=",
                    "--", pushURL, "+\(branchRef):\(trackingRef)",
                ])
                try GitService.assertSuccess(fetch, op: "Fetch remote tracking ref")
                for (key, value) in [("remote", remote), ("merge", "refs/heads/\(branch)")] {
                    let configuration = try await run(["config", "--local", "branch.\(target.branch).\(key)", value])
                    try GitService.assertSuccess(configuration, op: "Configure branch upstream")
                }
            },
            currentReviewRequestExists: { target in
                try await reviewLoop.currentReviewRequest(remote: target.remote, branch: target.upstreamBranch ?? target.branch,
                    headOwner: target.headOwner, baseBranch: target.baseBranch) != nil
            },
            createReviewRequest: { target, subject, body in
                try await reviewLoop.createReviewRequest(remote: target.remote, branch: target.upstreamBranch ?? target.branch,
                    headOwner: target.headOwner, baseBranch: target.baseBranch,
                    title: subject, body: body, draft: target.createAsDraft)
            },
            syncGG: syncGG,
            refreshAfterCompletion: refreshAfterCompletion
        )
    }
}

enum CommitPublishActivity: Equatable {
    case idle
    case committing
    case pushing
    case creatingReviewRequest
    case syncing

    func actionLabel(reviewRequestLabel: String) -> String? {
        switch self {
        case .idle: nil
        case .committing: "Committing..."
        case .pushing: "Pushing..."
        case .creatingReviewRequest: "Creating \(reviewRequestLabel)..."
        case .syncing: "Syncing..."
        }
    }
}

enum CommitPublishWorkflowError: LocalizedError, Equatable {
    case branchMismatch(expected: String, actual: String)
    case headMismatch(expected: String, actual: String)
    case invalidDestination(phase: CommitPublishPhase)
    case missingPushDestination
    case incompatiblePushRemote
    case pushDestinationChanged
    case publishedAmend

    var errorDescription: String? {
        switch self {
        case .branchMismatch:
            return "The current branch changed before publishing could begin."
        case .headMismatch:
            return "The current commit changed before publishing could resume."
        case .invalidDestination(let phase):
            return "The publish checkpoint cannot continue its \(phase.rawValue) phase."
        case .missingPushDestination:
            return "The publish checkpoint has no captured push destination."
        case .incompatiblePushRemote:
            return "The branch upstream is incompatible with the selected review host."
        case .pushDestinationChanged:
            return "The push destination changed. Restore the captured remote URL before retrying."
        case .publishedAmend:
            return "This commit is already published. Commit locally or turn off Amend before publishing."
        }
    }
}

@MainActor
@Observable
final class CommitPublishWorkflow {
    private let operations: CommitPublishOperations
    private let onCheckpointChange: (CommitPublishCheckpoint?) throws -> Void

    private(set) var activity: CommitPublishActivity = .idle
    private(set) var lastError: Error?
    private var activeRunID: UUID?

    init(
        operations: CommitPublishOperations,
        onCheckpointChange: @escaping (CommitPublishCheckpoint?) throws -> Void
    ) {
        self.operations = operations
        self.onCheckpointChange = onCheckpointChange
    }

    func start(
        subject: String,
        body: String,
        amend: Bool,
        destination: CommitPublishDestination
    ) async {
        guard let runID = beginRun() else { return }
        defer { endRun(runID) }

        lastError = nil
        activity = .committing
        let subject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            if case .review(let target) = destination {
                try await operations.validateReviewTarget(target)
                try Task.checkCancellation()
            } else if case .gg(let target) = destination, let target {
                try await operations.validateGGTarget(target)
                try Task.checkCancellation()
            }
            let createdCommit = try await operations.createCommit(subject, body, amend)
            let checkpointDestination: CommitPublishDestination
            switch destination {
            case .review:
                checkpointDestination = destination
            case .gg(var target):
                target?.expectedHeadSHA = createdCommit.commitSHA
                checkpointDestination = .gg(target)
            }
            let checkpoint = CommitPublishCheckpoint(
                commitSHA: createdCommit.commitSHA,
                baseRef: createdCommit.comparisonBase,
                commitTitle: createdCommit.editorTitle,
                subject: subject,
                body: body,
                destination: checkpointDestination,
                nextPhase: nextPhase(for: checkpointDestination)
            )
            try onCheckpointChange(checkpoint)
            try Task.checkCancellation()
            try await continueResuming(checkpoint, runID: runID)
        } catch is CancellationError {
            finishCancellation(runID)
        } catch {
            finish(with: error, runID: runID)
        }
    }

    func resume(_ checkpoint: CommitPublishCheckpoint) async {
        guard let runID = beginRun() else { return }
        defer { endRun(runID) }

        lastError = nil

        do {
            try onCheckpointChange(checkpoint)
            try Task.checkCancellation()
            try await continueResuming(checkpoint, runID: runID)
        } catch is CancellationError {
            finishCancellation(runID)
        } catch {
            finish(with: error, runID: runID)
        }
    }

    private func continueResuming(_ initialCheckpoint: CommitPublishCheckpoint, runID: UUID) async throws {
        try Task.checkCancellation()
        let currentHeadSHA = try await operations.currentHeadSHA()
        try Task.checkCancellation()
        var checkpoint = initialCheckpoint
        if currentHeadSHA != checkpoint.commitSHA, checkpoint.canReconcileGGHeadRewrite {
            checkpoint = checkpoint.resolvingGGCommitSHA(currentHeadSHA)
            try onCheckpointChange(checkpoint)
            try Task.checkCancellation()
        }
        guard currentHeadSHA == checkpoint.commitSHA else {
            throw CommitPublishWorkflowError.headMismatch(
                expected: checkpoint.commitSHA,
                actual: currentHeadSHA
            )
        }

        while true {
            switch checkpoint.nextPhase {
            case .push:
                guard case .review(let target) = checkpoint.destination else {
                    throw CommitPublishWorkflowError.invalidDestination(phase: .push)
                }

                activity = .pushing
                try Task.checkCancellation()
                let alreadyPublished = try await operations.remoteBranchContainsCommit(target, checkpoint.commitSHA)
                try Task.checkCancellation()
                if !alreadyPublished {
                    try await operations.push(target, checkpoint.commitSHA)
                }
                try await operations.configureUpstreamTracking(target)
                checkpoint.nextPhase = .createReviewRequest
                try onCheckpointChange(checkpoint)
                try Task.checkCancellation()

            case .createReviewRequest:
                guard case .review(let target) = checkpoint.destination else {
                    throw CommitPublishWorkflowError.invalidDestination(phase: .createReviewRequest)
                }

                if !target.reviewRequestExisted {
                    activity = .creatingReviewRequest
                    try Task.checkCancellation()
                    let requestExists = try await operations.currentReviewRequestExists(target)
                    try Task.checkCancellation()
                    if !requestExists {
                        _ = try await operations.createReviewRequest(target, checkpoint.subject, checkpoint.body)
                    }
                }
                try await complete(runID)
                return

            case .sync:
                guard case .gg(let target) = checkpoint.destination else {
                    throw CommitPublishWorkflowError.invalidDestination(phase: .sync)
                }

                activity = .syncing
                try Task.checkCancellation()
                if let target {
                    try await operations.validateGGTarget(target)
                    try Task.checkCancellation()
                    try await operations.syncGGForTarget(target)
                } else {
                    try await operations.syncGG()
                }
                let postSyncHeadSHA = try await operations.currentHeadSHA()
                try Task.checkCancellation()
                if postSyncHeadSHA != checkpoint.commitSHA {
                    checkpoint = checkpoint.resolvingGGCommitSHA(postSyncHeadSHA)
                    try onCheckpointChange(checkpoint)
                    try Task.checkCancellation()
                }
                try await complete(runID)
                return
            }
        }
    }

    private func nextPhase(for destination: CommitPublishDestination) -> CommitPublishPhase {
        switch destination {
        case .review:
            return .push
        case .gg:
            return .sync
        }
    }

    private func complete(_ runID: UUID) async throws {
        try onCheckpointChange(nil)
        activity = .idle
        lastError = nil
        endRun(runID)
        try Task.checkCancellation()
        await operations.refreshAfterCompletion()
    }

    private func beginRun() -> UUID? {
        guard activeRunID == nil else { return nil }
        let runID = UUID()
        activeRunID = runID
        return runID
    }

    private func endRun(_ runID: UUID) {
        guard activeRunID == runID else { return }
        activeRunID = nil
    }

    private func finishCancellation(_ runID: UUID) {
        guard activeRunID == runID else { return }
        activity = .idle
        lastError = nil
    }

    private func finish(with error: Error, runID: UUID) {
        guard activeRunID == runID else { return }
        activity = .idle
        lastError = error
    }
}

private extension CommitPublishCheckpoint {
    var canReconcileGGHeadRewrite: Bool {
        guard nextPhase == .sync,
              case .gg(.some) = destination
        else { return false }
        return true
    }

    func resolvingGGCommitSHA(_ commitSHA: String) -> Self {
        var destination = destination
        if case .gg(var target) = destination {
            target?.expectedHeadSHA = commitSHA
            destination = .gg(target)
        }
        return .init(
            commitSHA: commitSHA,
            baseRef: baseRef,
            commitTitle: "\(commitSHA.prefix(7)) \(subject)",
            subject: subject,
            body: body,
            destination: destination,
            nextPhase: nextPhase
        )
    }
}
