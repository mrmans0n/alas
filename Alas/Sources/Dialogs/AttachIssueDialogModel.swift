import Foundation
import Observation

@Observable
@MainActor
final class AttachIssueDialogModel {
    enum Phase: Equatable {
        case entry
        case resolving
        case confirmation
    }

    struct Environment {
        let resolve: (String) async throws -> ResolvedIssue
        let projects: () -> [ProjectConfig]
        let configuredBranchPrefix: (String) -> String
    }

    var reference = "" {
        didSet {
            guard oldValue != reference else { return }
            generation += 1
            if phase != .entry {
                phase = .entry
            }
            resolved = nil
            fallback = nil
            canContinueManually = false
            errorMessage = nil
            promptIsUserOwned = false
        }
    }
    private(set) var phase: Phase = .entry
    private(set) var resolved: ResolvedIssue?
    private(set) var projectID: String?
    var title = "" {
        didSet {
            guard oldValue != title else { return }
            refreshGeneratedPromptIfNeeded()
        }
    }
    var context = "" {
        didSet {
            guard oldValue != context else { return }
            refreshGeneratedPromptIfNeeded()
        }
    }
    var prompt = ""
    var errorMessage: String?
    private(set) var canContinueManually = false
    private var generation = 0
    private var promptIsUserOwned = false
    private var fallback: ResolvedIssue?

    private let environment: Environment

    init(environment: Environment, initialDraft: AttachedIssueDraft? = nil) {
        self.environment = environment
        if let initialDraft {
            reference = initialDraft.source.canonicalURL.absoluteString
            resolved = .init(
                source: initialDraft.source,
                repositoryLocator: initialDraft.source.repositoryLocator,
                candidateProjectIDs: initialDraft.projectID.map { [$0] } ?? [],
                selectedProjectID: initialDraft.projectID
            )
            projectID = initialDraft.projectID
            title = initialDraft.source.title
            context = initialDraft.source.body
            prompt = initialDraft.prompt
            promptIsUserOwned = initialDraft.prompt != IssuePromptBuilder.build(source: initialDraft.source)
            phase = .confirmation
        }
    }

    var branchSeed: String {
        guard let source = draftSource else { return "" }
        return IssueBranchName.make(
            displayReference: source.displayReference,
            title: source.title,
            prefix: environment.configuredBranchPrefix(projectID ?? "")
        )
    }

    func resolve() async {
        let capturedReference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !capturedReference.isEmpty else { return }

        generation += 1
        let capturedGeneration = generation
        phase = .resolving
        errorMessage = nil
        canContinueManually = false
        fallback = nil

        do {
            let resolution = try await environment.resolve(capturedReference)
            guard accepts(capturedGeneration, reference: capturedReference) else { return }
            adopt(resolution)
        } catch let failure as IssueResolutionFailure {
            guard accepts(capturedGeneration, reference: capturedReference) else { return }
            phase = .entry
            fallback = failure.fallback
            canContinueManually = true
            errorMessage = failure.message
        } catch {
            guard accepts(capturedGeneration, reference: capturedReference) else { return }
            phase = .entry
            errorMessage = error.localizedDescription
        }
    }

    func continueManually() async {
        guard let fallback else { return }
        adopt(fallback)
    }

    func cancelResolution() {
        generation += 1
        phase = .entry
        resolved = nil
        fallback = nil
        canContinueManually = false
        errorMessage = nil
    }

    func setPrompt(_ prompt: String) {
        self.prompt = prompt
        promptIsUserOwned = true
    }

    func makeDraft() -> AttachedIssueDraft? {
        guard phase == .confirmation,
              var source = resolved?.source,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }

        source = updated(source)
        return AttachedIssueDraft(
            source: source,
            projectID: projectID,
            branchSeed: IssueBranchName.make(
                displayReference: source.displayReference,
                title: source.title,
                prefix: environment.configuredBranchPrefix(projectID ?? "")
            ),
            prompt: prompt
        )
    }

    private var draftSource: IssueSnapshot? {
        resolved.map { updated($0.source) }
    }

    private func accepts(_ capturedGeneration: Int, reference capturedReference: String) -> Bool {
        generation == capturedGeneration
            && reference.trimmingCharacters(in: .whitespacesAndNewlines) == capturedReference
    }

    private func adopt(_ resolution: ResolvedIssue) {
        resolved = resolution
        projectID = selectedProjectID(for: resolution)
        title = resolution.source.title
        context = resolution.source.body
        if !promptIsUserOwned {
            prompt = IssuePromptBuilder.build(source: resolution.source)
        }
        fallback = nil
        canContinueManually = false
        errorMessage = nil
        phase = .confirmation
    }

    private func refreshGeneratedPromptIfNeeded() {
        guard !promptIsUserOwned, phase == .confirmation, let source = draftSource else { return }
        prompt = IssuePromptBuilder.build(source: source)
    }

    private func selectedProjectID(for resolution: ResolvedIssue) -> String? {
        let candidates = Set(resolution.candidateProjectIDs)
        let projectIDs = environment.projects().map(\.id)
        if let selected = resolution.selectedProjectID,
           candidates.contains(selected),
           projectIDs.contains(selected) {
            return selected
        }
        return projectIDs.first { candidates.contains($0) }
    }

    private func updated(_ source: IssueSnapshot) -> IssueSnapshot {
        .init(
            identity: source.identity,
            canonicalURL: source.canonicalURL,
            providerLabel: source.providerLabel,
            displayReference: source.displayReference,
            repositoryLocator: source.repositoryLocator,
            title: title,
            body: context,
            state: source.state,
            labels: source.labels,
            assignees: source.assignees,
            providerUpdatedAt: source.providerUpdatedAt,
            capturedAt: source.capturedAt,
            refreshError: source.refreshError,
            contentOrigin: source.contentOrigin,
            isEditable: source.isEditable,
            isRefreshable: source.isRefreshable
        )
    }
}
