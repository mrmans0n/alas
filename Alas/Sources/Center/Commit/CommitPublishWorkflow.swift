import Foundation
import Observation

struct CommitPublishCreatedCommit: Equatable, Sendable {
    let commitSHA: String
    let comparisonBase: String
    let editorTitle: String
}

@MainActor
struct CommitPublishOperations {
    var createCommit: (_ subject: String, _ body: String, _ amend: Bool) async throws -> CommitPublishCreatedCommit
    var currentHeadSHA: () async throws -> String
    var remoteBranchContainsCommit: (_ target: CommitPublishReviewTarget, _ commitSHA: String) async throws -> Bool
    var push: (_ target: CommitPublishReviewTarget, _ commitSHA: String) async throws -> Void
    var currentReviewRequestExists: (_ target: CommitPublishReviewTarget) async throws -> Bool
    var createReviewRequest: (_ target: CommitPublishReviewTarget, _ subject: String, _ body: String) async throws -> URL
    var syncGG: () async throws -> Void
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
                guard let pushURL = target.pushURL else { throw CommitPublishWorkflowError.missingPushDestination }
                return try await contains(pushURL, target.upstreamBranch ?? target.branch, sha)
            },
            push: { target, _ in
                guard let pushURL = target.pushURL else { throw CommitPublishWorkflowError.missingPushDestination }
                let remote = target.pushRemoteName ?? target.remoteName
                let destination = try await run(["remote", "get-url", "--push", remote])
                try GitService.assertSuccess(destination, op: "Resolve push destination")
                guard destination.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == pushURL else {
                    throw CommitPublishWorkflowError.pushDestinationChanged
                }
                let ref = target.upstreamBranch.map { "HEAD:\($0)" } ?? target.branch
                let result = try await run(["push", "-u", remote, ref])
                guard result.exitCode == 0 else {
                    throw NSError(domain: "CommitPublish", code: Int(result.exitCode),
                        userInfo: [NSLocalizedDescriptionKey: RightPaneState.reviewLoopPushFailureMessage(result)])
                }
            },
            currentReviewRequestExists: { target in
                try await reviewLoop.currentReviewRequest(remote: target.remote, branch: target.branch,
                    headOwner: target.headOwner, baseBranch: target.baseBranch) != nil
            },
            createReviewRequest: { target, subject, body in
                try await reviewLoop.createReviewRequest(remote: target.remote, branch: target.branch,
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
    case headMismatch(expected: String, actual: String)
    case invalidDestination(phase: CommitPublishPhase)
    case missingPushDestination
    case pushDestinationChanged
    case publishedAmend

    var errorDescription: String? {
        switch self {
        case .headMismatch:
            return "The current commit changed before publishing could resume."
        case .invalidDestination(let phase):
            return "The publish checkpoint cannot continue its \(phase.rawValue) phase."
        case .missingPushDestination:
            return "The publish checkpoint has no captured push destination."
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
    private let onCheckpointChange: (CommitPublishCheckpoint?) -> Void

    private(set) var activity: CommitPublishActivity = .idle
    private(set) var lastError: Error?
    private var activeRunID: UUID?

    init(
        operations: CommitPublishOperations,
        onCheckpointChange: @escaping (CommitPublishCheckpoint?) -> Void
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
            let createdCommit = try await operations.createCommit(subject, body, amend)
            let checkpoint = CommitPublishCheckpoint(
                commitSHA: createdCommit.commitSHA,
                baseRef: createdCommit.comparisonBase,
                commitTitle: createdCommit.editorTitle,
                subject: subject,
                body: body,
                destination: destination,
                nextPhase: nextPhase(for: destination)
            )
            onCheckpointChange(checkpoint)
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
        guard currentHeadSHA == initialCheckpoint.commitSHA else {
            throw CommitPublishWorkflowError.headMismatch(
                expected: initialCheckpoint.commitSHA,
                actual: currentHeadSHA
            )
        }

        var checkpoint = initialCheckpoint
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
                checkpoint.nextPhase = .createReviewRequest
                onCheckpointChange(checkpoint)
                try Task.checkCancellation()

            case .createReviewRequest:
                guard case .review(let target) = checkpoint.destination else {
                    throw CommitPublishWorkflowError.invalidDestination(phase: .createReviewRequest)
                }

                activity = .creatingReviewRequest
                try Task.checkCancellation()
                let requestExists = try await operations.currentReviewRequestExists(target)
                try Task.checkCancellation()
                if !requestExists {
                    _ = try await operations.createReviewRequest(target, checkpoint.subject, checkpoint.body)
                }
                try await complete(runID)
                return

            case .sync:
                guard case .gg = checkpoint.destination else {
                    throw CommitPublishWorkflowError.invalidDestination(phase: .sync)
                }

                activity = .syncing
                try Task.checkCancellation()
                try await operations.syncGG()
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
        onCheckpointChange(nil)
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
