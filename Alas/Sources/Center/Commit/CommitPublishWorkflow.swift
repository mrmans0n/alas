import Foundation

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
}

enum CommitPublishActivity: Equatable {
    case idle
    case committing
    case pushing
    case creatingReviewRequest
    case syncing
}

enum CommitPublishWorkflowError: LocalizedError, Equatable {
    case headMismatch(expected: String, actual: String)
    case invalidDestination(phase: CommitPublishPhase)

    var errorDescription: String? {
        switch self {
        case .headMismatch:
            return "The current commit changed before publishing could resume."
        case .invalidDestination(let phase):
            return "The publish checkpoint cannot continue its \(phase.rawValue) phase."
        }
    }
}

@MainActor
final class CommitPublishWorkflow {
    private let operations: CommitPublishOperations
    private let onCheckpointChange: (CommitPublishCheckpoint?) -> Void

    private(set) var activity: CommitPublishActivity = .idle
    private(set) var lastError: Error?

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
        lastError = nil
        activity = .committing

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
            await resume(checkpoint)
        } catch {
            finish(with: error)
        }
    }

    func resume(_ checkpoint: CommitPublishCheckpoint) async {
        lastError = nil

        do {
            let currentHeadSHA = try await operations.currentHeadSHA()
            guard currentHeadSHA == checkpoint.commitSHA else {
                throw CommitPublishWorkflowError.headMismatch(
                    expected: checkpoint.commitSHA,
                    actual: currentHeadSHA
                )
            }

            var checkpoint = checkpoint
            while true {
                switch checkpoint.nextPhase {
                case .push:
                    guard case .review(let target) = checkpoint.destination else {
                        throw CommitPublishWorkflowError.invalidDestination(phase: .push)
                    }

                    activity = .pushing
                    let alreadyPublished = try await operations.remoteBranchContainsCommit(target, checkpoint.commitSHA)
                    if !alreadyPublished {
                        try await operations.push(target, checkpoint.commitSHA)
                    }
                    checkpoint.nextPhase = .createReviewRequest
                    onCheckpointChange(checkpoint)

                case .createReviewRequest:
                    guard case .review(let target) = checkpoint.destination else {
                        throw CommitPublishWorkflowError.invalidDestination(phase: .createReviewRequest)
                    }

                    activity = .creatingReviewRequest
                    let requestExists = try await operations.currentReviewRequestExists(target)
                    if !requestExists {
                        _ = try await operations.createReviewRequest(target, checkpoint.subject, checkpoint.body)
                    }
                    await complete()
                    return

                case .sync:
                    guard case .gg = checkpoint.destination else {
                        throw CommitPublishWorkflowError.invalidDestination(phase: .sync)
                    }

                    activity = .syncing
                    try await operations.syncGG()
                    await complete()
                    return
                }
            }
        } catch {
            finish(with: error)
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

    private func complete() async {
        onCheckpointChange(nil)
        activity = .idle
        lastError = nil
        await operations.refreshAfterCompletion()
    }

    private func finish(with error: Error) {
        activity = .idle
        lastError = error
    }
}
