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
