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
        let loadSuggestions: @Sendable (String, Int) async throws -> [CodeHostIssueSuggestion]
        let selectedProjectID: String
        let projects: () -> [ProjectConfig]
        let clipboardText: () -> String?
        /// Called with each resolved issue so the parent can start naming the
        /// worktree while the user reviews the confirmation step, and with nil
        /// when the user backs out of that step.
        let resolvedIssueChanged: (IssueSnapshot?) -> Void
        let classifyKind: (@MainActor (IssueSnapshot) async -> IssueKind?)?

        init(
            resolve: @escaping (String) async throws -> ResolvedIssue,
            loadSuggestions: @escaping @Sendable (String, Int) async throws -> [CodeHostIssueSuggestion],
            selectedProjectID: String,
            projects: @escaping () -> [ProjectConfig],
            clipboardText: @escaping () -> String? = { Clipboard.read() },
            resolvedIssueChanged: @escaping (IssueSnapshot?) -> Void = { _ in },
            classifyKind: (@MainActor (IssueSnapshot) async -> IssueKind?)? = nil
        ) {
            self.resolve = resolve
            self.loadSuggestions = loadSuggestions
            self.selectedProjectID = selectedProjectID
            self.projects = projects
            self.clipboardText = clipboardText
            self.resolvedIssueChanged = resolvedIssueChanged
            self.classifyKind = classifyKind
        }
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
            resetKind()
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
    private(set) var kind: IssueKind?
    private(set) var kindOrigin: IssueKindOrigin?
    private(set) var isDetectingKind = false
    private var kindTask: Task<Void, Never>?
    private var kindGeneration = 0
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
            kind = initialDraft.kind
            kindOrigin = initialDraft.kindOrigin
            promptIsUserOwned = initialDraft.prompt
                != IssuePromptBuilder.build(source: initialDraft.source, kind: initialDraft.kind)
            phase = .confirmation
        } else {
            reference = IssueClipboardPrefill.candidate(from: environment.clipboardText()) ?? ""
        }
    }

    var branchSeed: String {
        guard let source = draftSource else { return "" }
        return IssueBranchName.make(
            displayReference: source.displayReference,
            title: source.title
        )
    }

    var autocompleteProjectID: String {
        environment.selectedProjectID
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
        resetKind()
        environment.resolvedIssueChanged(nil)
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
                title: source.title
            ),
            prompt: prompt,
            kind: kind,
            kindOrigin: kindOrigin
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
        applyInitialKind(for: resolution.source)
        if !promptIsUserOwned {
            prompt = IssuePromptBuilder.build(source: resolution.source, kind: kind)
        }
        fallback = nil
        canContinueManually = false
        errorMessage = nil
        phase = .confirmation
        environment.resolvedIssueChanged(resolution.source)
    }

    private func refreshGeneratedPromptIfNeeded() {
        guard !promptIsUserOwned, phase == .confirmation, let source = draftSource else { return }
        prompt = IssuePromptBuilder.build(source: source, kind: kind)
    }

    var kindCaption: String? {
        if isDetectingKind { return "Detecting…" }
        switch kindOrigin {
        case .rule(let reason): return reason
        case .suggested: return "suggested"
        case .user, nil: return nil
        }
    }

    var canResetPrompt: Bool {
        promptIsUserOwned && phase == .confirmation
    }

    /// A user pick always wins: it cancels detection and is never overwritten.
    func setKind(_ kind: IssueKind?) {
        cancelKindDetection()
        self.kind = kind
        kindOrigin = .user
        refreshGeneratedPromptIfNeeded()
    }

    func resetPromptToTemplate() {
        promptIsUserOwned = false
        refreshGeneratedPromptIfNeeded()
    }

    func cancelKindDetection() {
        kindGeneration += 1
        kindTask?.cancel()
        kindTask = nil
        isDetectingKind = false
    }

    private func resetKind() {
        cancelKindDetection()
        kind = nil
        kindOrigin = nil
    }

    /// Rules decide synchronously. Otherwise the model is asked in the
    /// background, and its answer applies only if nothing the user did has
    /// superseded it.
    private func applyInitialKind(for source: IssueSnapshot) {
        guard kindOrigin != .user else { return }
        cancelKindDetection()
        if let decision = IssueKindRules.classify(source) {
            kind = decision.kind
            kindOrigin = .rule(reason: decision.reason)
            return
        }
        kind = nil
        kindOrigin = nil
        guard let classify = environment.classifyKind else { return }
        kindGeneration += 1
        let generation = kindGeneration
        isDetectingKind = true
        kindTask = Task { [weak self] in
            let suggested = await classify(source)
            guard let self, !Task.isCancelled, generation == self.kindGeneration else { return }
            self.isDetectingKind = false
            self.kindTask = nil
            guard let suggested, self.kindOrigin != .user, !self.promptIsUserOwned else { return }
            self.kind = suggested
            self.kindOrigin = .suggested
            self.refreshGeneratedPromptIfNeeded()
        }
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
            isRefreshable: source.isRefreshable,
            nativeType: source.nativeType
        )
    }
}
