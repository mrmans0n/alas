import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasAgents

/// Decides what to do about a repository hook nobody has approved yet, or one
/// that could not be loaded.
public struct RepoHookPrompter {
    public var decide: @MainActor (_ hook: RepoHook, _ projectID: String, _ context: RepoHookApprovalContext) async -> RepoHookApprovalDecision
    public var decideFailure: @MainActor (_ failure: RepoHookFailure, _ context: RepoHookApprovalContext) async -> RepoHookApprovalDecision

    public init(
        decide: @escaping @MainActor (RepoHook, String, RepoHookApprovalContext) async -> RepoHookApprovalDecision,
        decideFailure: @escaping @MainActor (RepoHookFailure, RepoHookApprovalContext) async -> RepoHookApprovalDecision
    ) {
        self.decide = decide
        self.decideFailure = decideFailure
    }

    /// Without anyone to ask: hooks already approved run, the rest are
    /// skipped, and so are hooks that cannot be loaded.
    public static var skipping: RepoHookPrompter {
        RepoHookPrompter(decide: { _, _, _ in .skip }, decideFailure: { _, _ in .skip })
    }

    /// Asks through the queue the app presents.
    @MainActor
    public static func queue(_ queue: RepoHookApprovalQueue) -> RepoHookPrompter {
        RepoHookPrompter(
            decide: { await queue.requestDecision(hook: $0, projectID: $1, context: $2) },
            decideFailure: { await queue.requestFailureDecision(failure: $0, context: $1) }
        )
    }
}

public enum RepoHookPreflightError: LocalizedError {
    case cancelled
    case approvalPersistenceFailed

    public var errorDescription: String? {
        switch self {
        case .cancelled: "Repository hook approval was cancelled."
        case .approvalPersistenceFailed: "Alas couldn't save this repository hook approval. The hook was not run."
        }
    }
}

/// What to do about a repository hook before work a paired Mac starts.
public enum RepoHookGate: Equatable, Sendable {
    /// Go ahead, running this approved script, or none.
    case ready(String?)
    /// Go ahead without the unapproved hook, and say it was not run.
    case skippedUnapproved
    /// Start nothing: the paired Mac asks its user about this hook first.
    case needsApproval(PeerRepoHook)
}

/// Work a paired Mac started stopped for its user to approve `hook`.
public struct RepoHookApprovalRequired: Error, Equatable, Sendable {
    public let hook: PeerRepoHook

    public init(hook: PeerRepoHook) {
        self.hook = hook
    }
}

extension AlasCoreContext {
    /// Decides the repository hook for `event` of work a paired Mac starts,
    /// as `consent` says: an unapproved hook is approved only when the
    /// paired Mac approved this very script, and is otherwise sent back for
    /// approval, skipped when it said so, or skipped with a notice when it
    /// cannot ask (nil). Throws when an approval cannot be saved.
    @_spi(AppHost) public func gateRepoHook(
        event: RepoHookEvent,
        project: ProjectConfig,
        consent: RepoHookConsent?,
        load: () async -> RepoHookLoadResult
    ) async throws -> RepoHookGate {
        guard Self.usesInheritedRepoHook(event: event, project: project),
              case let .loaded(hook) = await load() else {
            return .ready(nil)
        }
        if projects.isRepoHookApproved(projectId: project.id, hash: hook.hash) {
            return .ready(hook.text)
        }
        switch consent {
        case .approve(let hash) where hash == hook.hash:
            try persistRepoHookApproval(projectId: project.id, hash: hook.hash)
            return .ready(hook.text)
        case .ask, .approve:
            return .needsApproval(PeerRepoHook(hook))
        case .skip:
            return .ready(nil)
        case nil:
            return .skippedUnapproved
        }
    }

    /// The repository's hook for `event`, when the project inherits it and it
    /// is approved: approved earlier, or now through `prompter` (the
    /// environment's `repoHookPrompter` when nil). Nil when there is none or
    /// it is skipped; throws when it is cancelled.
    @_spi(AppHost) public func preparedRepoHook(
        event: RepoHookEvent,
        project: ProjectConfig,
        worktree: Worktree,
        context: RepoHookApprovalContext,
        includeUserStartupScript: Bool = true,
        prompter: RepoHookPrompter? = nil
    ) async throws -> String? {
        guard includeUserStartupScript, Self.usesInheritedRepoHook(event: event, project: project) else {
            return nil
        }
        let prompter = prompter ?? environment.repoHookPrompter
        while true {
            switch await environment.repoHookLoader.load(event: event, worktreeRoot: worktree.path, host: project.host) {
            case .missing, .empty:
                return nil
            case let .failed(source, message):
                switch await prompter.decideFailure(.init(event: event, source: source, message: message), context) {
                case .retry, .approve: continue
                case .skip: return nil
                case .cancel: throw RepoHookPreflightError.cancelled
                }
            case let .loaded(hook):
                if projects.isRepoHookApproved(projectId: project.id, hash: hook.hash) {
                    return hook.text
                }
                switch await prompter.decide(hook, project.id, context) {
                case .approve:
                    while true {
                        do {
                            try persistRepoHookApproval(projectId: project.id, hash: hook.hash)
                            return hook.text
                        } catch {
                            let failure = RepoHookFailure(event: event, source: hook.source, message: error.localizedDescription)
                            switch await prompter.decideFailure(failure, context) {
                            case .retry, .approve: continue
                            case .skip: return nil
                            case .cancel: throw RepoHookPreflightError.cancelled
                            }
                        }
                    }
                case .skip:
                    return nil
                case .retry:
                    continue
                case .cancel:
                    throw RepoHookPreflightError.cancelled
                }
            }
        }
    }

    /// Records the approval and persists it; nothing is kept if saving fails.
    @_spi(AppHost) public func persistRepoHookApproval(projectId: String, hash: String) throws {
        guard projects.approveRepoHook(projectId: projectId, hash: hash) else {
            if projects.isRepoHookApproved(projectId: projectId, hash: hash) {
                return
            }
            throw RepoHookPreflightError.approvalPersistenceFailed
        }
        do {
            try saveProjects()
        } catch {
            projects.revokeRepoHookApproval(projectId: projectId, hash: hash)
            throw RepoHookPreflightError.approvalPersistenceFailed
        }
    }

    /// Runs a new worktree's create script: the global one, the repository's
    /// approved hook and the project's own, combined as configured. It runs
    /// in the worktree, over SSH for remote ones, and its failure does not
    /// fail the creation. Throws only when the hook's approval is cancelled.
    func runWorktreeCreateScripts(
        project: ProjectConfig,
        worktree: Worktree,
        includeUserStartupScript: Bool = true,
        prompter: RepoHookPrompter? = nil
    ) async throws {
        let repoScript = try await preparedRepoHook(
            event: .worktreeCreate,
            project: project,
            worktree: worktree,
            context: .worktreeCreate,
            includeUserStartupScript: includeUserStartupScript,
            prompter: prompter
        )
        let script = StartupScriptResolver.worktreeCreateScript(
            global: environment.globalTerminalConfig(),
            repoScript: repoScript,
            project: project
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        guard includeUserStartupScript, !script.isEmpty else { return }
        if let host = project.host ?? RemoteHostRegistry.shared.host(forPath: worktree.path.path) {
            _ = try? await RemoteExec.run(host: host, cwd: worktree.path.path, command: script)
        } else {
            _ = try? await Process.run("/bin/zsh", args: ["-c", script], cwd: worktree.path)
        }
    }

    static func usesInheritedRepoHook(event: RepoHookEvent, project: ProjectConfig) -> Bool {
        let mode: ProjectStartupScriptMode = switch event {
        case .sessionOpen: project.startupScripts.sessionOpenMode
        case .worktreeCreate: project.startupScripts.worktreeCreateMode
        }
        return mode.usesInheritedScripts
    }
}
