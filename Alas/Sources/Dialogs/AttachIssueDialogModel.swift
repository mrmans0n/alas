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

        init(
            resolve: @escaping (String) async throws -> ResolvedIssue,
            loadSuggestions: @escaping @Sendable (String, Int) async throws -> [CodeHostIssueSuggestion],
            selectedProjectID: String,
            projects: @escaping () -> [ProjectConfig],
            clipboardText: @escaping () -> String? = { Clipboard.read() },
            resolvedIssueChanged: @escaping (IssueSnapshot?) -> Void = { _ in }
        ) {
            self.resolve = resolve
            self.loadSuggestions = loadSuggestions
            self.selectedProjectID = selectedProjectID
            self.projects = projects
            self.clipboardText = clipboardText
            self.resolvedIssueChanged = resolvedIssueChanged
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
            resolvesDirectly = false
            resetKind()
        }
    }
    private(set) var phase: Phase = .entry
    /// The sheet opened on a known link and skips the entry step: it shows the
    /// confirmation layout while resolving. Cleared once resolution fails or
    /// the user goes back to change the link, which lands on the entry step.
    private(set) var resolvesDirectly = false
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
    private var fallback: ResolvedIssue?

    private let environment: Environment

    /// `directReference` opens on that link and resolves it right away;
    /// `initialDraft` reopens an attached ticket. Otherwise the entry step
    /// starts prefilled from the clipboard.
    init(
        environment: Environment,
        initialDraft: AttachedIssueDraft? = nil,
        directReference: String? = nil
    ) {
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
        } else if let directReference {
            reference = directReference
            resolvesDirectly = true
        } else {
            reference = IssueClipboardPrefill.candidate(from: environment.clipboardText()) ?? ""
        }
    }

    /// Starts resolving the link the sheet was opened on. Runs once: after a
    /// failure or a change of link the user drives resolution from the entry step.
    func resolveDirectReference() async {
        guard resolvesDirectly, phase == .entry else { return }
        await resolve()
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
            resolvesDirectly = false
            fallback = failure.fallback
            canContinueManually = true
            errorMessage = failure.message
        } catch {
            guard accepts(capturedGeneration, reference: capturedReference) else { return }
            phase = .entry
            resolvesDirectly = false
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
        resolvesDirectly = false
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
        switch kindOrigin {
        case .rule(let reason): return reason
        case .user, nil: return nil
        }
    }

    var canResetPrompt: Bool {
        promptIsUserOwned && phase == .confirmation
    }

    /// A user pick always wins and is never overwritten.
    func setKind(_ kind: IssueKind?) {
        self.kind = kind
        kindOrigin = .user
        refreshGeneratedPromptIfNeeded()
    }

    func resetPromptToTemplate() {
        promptIsUserOwned = false
        refreshGeneratedPromptIfNeeded()
    }

    private func resetKind() {
        kind = nil
        kindOrigin = nil
    }

    /// Rules decide from provider metadata. A user pick is never overwritten;
    /// without a rule decision the ticket stays unclassified.
    private func applyInitialKind(for source: IssueSnapshot) {
        guard kindOrigin != .user else { return }
        if let decision = IssueKindRules.classify(source) {
            kind = decision.kind
            kindOrigin = .rule(reason: decision.reason)
        } else {
            kind = nil
            kindOrigin = nil
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
