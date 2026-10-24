import Foundation
import AlasModel
import AlasAgents
import AlasAgentKit
import AlasACP

/// The built-in `alas` MCP server and CLI env for agents a headless host
/// starts, as the app gives its agents: stdio only, with the screen-bound
/// tools hidden (`ALAS_MCP_HEADLESS`).
// ponytail: no relink after a socket rebind; agents reattach on their next session
@MainActor
public struct HeadlessAlasTools {
    let binDir: URL
    let socketServer: AgentHookSocketServer
    let config: @MainActor () -> AppConfig
    let core: @MainActor () -> AlasCoreContext?

    public init(
        binDir: URL,
        socketServer: AgentHookSocketServer,
        config: @escaping @MainActor () -> AppConfig,
        core: @escaping @MainActor () -> AlasCoreContext?
    ) {
        self.binDir = binDir
        self.socketServer = socketServer
        self.config = config
        self.core = core
    }

    func socketPath(sessionId: String) -> String? {
        socketServer.linkSession(leafId: AgentHookSocketServer.acpSessionLinkKey(sessionId)) ?? socketServer.socketPath
    }

    private func project(of worktree: Worktree) -> ProjectConfig? {
        core()?.projects.projects.first { $0.id == worktree.projectId }
    }

    /// Repo config participates on local projects only, as in the app.
    private func repoConfig(_ project: ProjectConfig, worktreeRoot: URL) -> RepoConfig? {
        guard project.host == nil else { return nil }
        return core()?.repoConfigStore.config(worktreeRoot: worktreeRoot)
    }

    func projectContext(for worktree: Worktree) -> MCPProjectContext? {
        guard let project = project(of: worktree) else { return nil }
        let repo = repoConfig(project, worktreeRoot: worktree.path)
        return MCPProjectContext(
            projectDirectory: project.path,
            configuredServers: project.mcpServers,
            repoServers: repo?.mcpServers ?? [],
            disabledRepoServerNames: Set(project.disabledRepoMCPServers),
            repoTrust: project.repoMCPTrust
        )
    }

    func attachment(_ context: BuiltInMCPAttachmentContext, worktree: Worktree) async -> BuiltInMCPAttachment {
        guard case .local = context.location, let core = core() else { return .omitted }
        let sessionId = context.sessionId
        let parentSessionId = await core.delegatedParentSessionID(for: sessionId)
        if let parentSessionId {
            core.rememberDelegatedSessionParent(childID: sessionId, parentID: parentSessionId)
        }
        let configuredServers: [ProjectMCPServer] = {
            guard let project = project(of: worktree) else { return [] }
            guard let repo = repoConfig(project, worktreeRoot: URL(fileURLWithPath: context.worktreePath)) else {
                return project.mcpServers
            }
            // An approved repo server named "alas" suppresses the built-in.
            return RepoMCPResolver.merge(
                appServers: project.mcpServers,
                repoServers: repo.mcpServers,
                disabledNames: Set(project.disabledRepoMCPServers),
                trust: project.repoMCPTrust
            ).active
        }()
        return .local(BuiltInAlasMCP.injection(
            enabled: config().harness.exposeAlasMCP,
            configuredServers: configuredServers,
            binaryPath: binDir.appendingPathComponent(TerminalCLIInjection.executableName).path,
            socketPath: socketPath(sessionId: sessionId),
            worktreePath: context.worktreePath,
            sessionId: sessionId,
            parentSessionId: parentSessionId,
            headless: true
        ))
    }

    func environment(worktreePath: String, sessionId: String) async -> [String: String]? {
        let parentSessionId = await core()?.delegatedParentSessionID(for: sessionId)
        return AlasCLIEnvInjection.environment(
            enabled: config().harness.exposeAlasMCP,
            binDirPath: binDir.path,
            socketPath: socketPath(sessionId: sessionId),
            worktreePath: worktreePath,
            sessionId: sessionId,
            parentSessionId: parentSessionId,
            basePATH: ACPProcessEnvironment.augmented()["PATH"]
        )
    }
}
