import AppKit
import Foundation

struct PluginStackInventoryCache {
    var inventory: StackInventory
    let revision: UInt64
}

extension AppState {
    /// Project identity and execution location come from Alas, never plugin-supplied paths.
    func pluginStackInventory(projectID: String, refresh: Bool) async -> StackInventory {
        let gate = GGProjectMutationGate.shared
        let revision = gate.revision(project: projectID)
        let busy = gate.isBusy(project: projectID)
        func unavailable(_ reason: String) -> StackInventory {
            StackInventory(complete: false, busy: busy, stacks: [], error: reason)
                .retainingKnownStacks(from: pluginStackInventories[projectID]?.inventory)
        }
        guard let project = projects.first(where: { $0.id == projectID }) else {
            return unavailable("This project is no longer available.")
        }
        guard project.host == nil, RemotePath.split(project.path) == nil, !project.isFolder else {
            return unavailable("Native gg stacks are unavailable for SSH and folder projects.")
        }
        guard ggInboxAvailable(projectId: projectID) else {
            return unavailable("Enable stacked diffs and install gg for this project.")
        }
        if !refresh, let cache = pluginStackInventories[projectID] {
            var inventory = cache.inventory
            inventory.busy = busy
            if let problem = gate.problem(project: projectID) { inventory.error = problem; inventory.complete = false }
            if cache.revision != revision || Date().timeIntervalSince1970 * 1000 - (inventory.fetchedAt ?? 0) > 30_000 {
                inventory.complete = false
                inventory.error = "Native stack inventory is stale. Refresh before taking an action."
            }
            return inventory.retainingKnownStacks(from: cache.inventory)
        }

        let service = GGService()
        var stacks: [NativeStack] = []
        var errors: [String] = []
        let worktrees = projectsManager.worktrees(projectId: projectID)
        do {
            let remotes = try await GitService().remotes(worktreePath: URL(fileURLWithPath: project.path))
            guard let remote = CodeHostRemoteDetector.detect(from: remotes) else {
                throw PluginStackError("The project's provider repository identity is unavailable.")
            }
            let directory = try await service.stackDirectory(repoPath: project.path)
            let branchUsername = GGConfigReader.branchUsername(repoPath: project.path)
            var owners: [String: [(Worktree, GGStackSnapshot)]] = [:]
            for worktree in worktrees where !worktree.path.isRemoteAlasPath {
                let context = ggWorktreeContext(project: project, worktree: worktree, branch: worktree.branch)
                guard context.permitsCurrentStackQuery else { continue }
                do {
                    let snapshot = try await service.currentStackSnapshot(worktreePath: worktree.path.path, requireRemoteRefresh: true)
                    if let name = snapshot.stack?.name { owners[name, default: []].append((worktree, snapshot)) }
                } catch {
                    errors.append("\(worktree.name): \(GGErrorPresentation.message(for: error))")
                }
            }
            for summary in directory.stacks {
                let candidates = owners.removeValue(forKey: summary.name) ?? []
                if candidates.count == 1, let (worktree, snapshot) = candidates.first, let stack = snapshot.stack {
                    stacks.append(try await pluginNativeStack(stack, project: project, remote: remote, worktree: worktree,
                                                              actionsAllowed: ggWorktreeContext(project: project, worktree: worktree, branch: worktree.branch).isActive))
                } else {
                    let knownOwnerID = candidates.isEmpty ? GGInboxWorktreeResolver.worktreeId(
                        stackName: summary.name, username: branchUsername,
                        worktrees: worktrees.map { (id: $0.id, branch: $0.branch) }
                    ) : nil
                    let reason = candidates.count > 1 ? "More than one worktree owns this stack. Resolve the ambiguity in native gg."
                        : knownOwnerID != nil ? "Open this worktree and refresh its native stack metadata before running this action."
                            : "Open this stack to create or reuse its native worktree before running this action."
                    let entries = try await summary.commits.sorted { $0.position < $1.position }.asyncMap { entry in
                        NativeStackEntry(id: entry.sha, sha: try await GitService().resolveRevision(at: URL(fileURLWithPath: project.path), ref: entry.sha),
                                         position: entry.position, title: entry.title)
                    }
                    var reasons = Dictionary(uniqueKeysWithValues: NativeStackAction.allCases.filter { $0 != .open }.map { ($0.rawValue, reason) })
                    if candidates.count > 1 { reasons["open"] = reason }
                    if GGInboxWorktreeResolver.hasAmbiguousLocalOwners(stackName: summary.name, worktrees: worktrees.map { (id: $0.id, branch: $0.branch) }) {
                        reasons["open"] = "More than one local worktree may own this stack. Resolve the ambiguity in native gg."
                    }
                    if knownOwnerID == nil, !summary.hasCompleteShape { reasons["open"] = "GG returned incomplete stack membership; refresh before following it." }
                    if !GGService.canFollowExistingStackName(summary.name) { reasons["open"] = "This stack name is not a canonical gg name and cannot be followed safely." }
                    if knownOwnerID == nil, !GGAvailability.shared.capabilities.clientOperationID { reasons["open"] = "Update gg to support native operation identifiers before following a stack." }
                    if knownOwnerID == nil, project.ggMode == .off { reasons["open"] = "Enable native gg for this project before following its stacks." }
                    if let knownOwner = worktrees.first(where: { $0.id == knownOwnerID }),
                       !ggWorktreeContext(project: project, worktree: knownOwner, branch: knownOwner.branch).isActive {
                        reasons["open"] = "Enable native gg for this stack's worktree before opening it."
                    }
                    stacks.append(NativeStack(id: pluginStackID(projectID, summary.name), name: summary.name, base: summary.base,
                                              host: remote.host, repo: remote.repositorySlug, worktree: knownOwnerID, complete: false, entries: entries,
                                              actions: reasons["open"] == nil ? [.open] : [], unavailableActions: reasons))
                }
            }
            // A detached/followed worktree can identify a stack absent from gg's username-scoped directory.
            for name in owners.keys.sorted() {
                guard let candidates = owners[name], candidates.count == 1,
                      let (worktree, snapshot) = candidates.first, let stack = snapshot.stack else {
                    errors.append("\(name): ambiguous worktree ownership.")
                    continue
                }
                stacks.append(try await pluginNativeStack(stack, project: project, remote: remote, worktree: worktree,
                                                          actionsAllowed: ggWorktreeContext(project: project, worktree: worktree, branch: worktree.branch).isActive))
            }
            do {
                let remoteDirectory = try await service.remoteStackDirectory(repoPath: project.path)
                let localIDs = Set(stacks.map(\.id))
                for discovered in remoteDirectory.stacks where !localIDs.contains(pluginStackID(projectID, discovered.name)) {
                    let reason = "Remote gg discovery cannot verify fresh heads, final base, or entry order. Check out this stack in native gg first."
                    stacks.append(NativeStack(id: pluginStackID(projectID, discovered.name), name: discovered.name, base: "",
                                              host: remote.host, repo: remote.repositorySlug, complete: false, entries: [], actions: [],
                                              unavailableActions: Dictionary(uniqueKeysWithValues: NativeStackAction.allCases.map { ($0.rawValue, reason) }),
                                              reviewNumbers: discovered.prNumbers))
                }
            } catch {
                errors.append("Remote stacks: \(GGErrorPresentation.message(for: error))")
            }
        } catch {
            errors.append(GGErrorPresentation.message(for: error))
        }
        let current = projects.first { $0.id == projectID }
        if let problem = gate.problem(project: projectID) { errors.append(problem) }
        if current != project || projectsManager.worktrees(projectId: projectID) != worktrees || gate.revision(project: projectID) != revision {
            errors.append("The project changed while native stacks were refreshing. Refresh and try again.")
        }
        let inventory = StackInventory(complete: errors.isEmpty, busy: gate.isBusy(project: projectID), stacks: stacks.sorted { $0.id < $1.id },
                                       fetchedAt: Date().timeIntervalSince1970 * 1000, error: errors.isEmpty ? nil : errors.joined(separator: "\n"))
            .retainingKnownStacks(from: pluginStackInventories[projectID]?.inventory)
        pluginStackInventories[projectID] = .init(inventory: inventory, revision: revision)
        return inventory
    }

    private func pluginStackID(_ projectID: String, _ name: String) -> String { "\(projectID):\(name)" }

    private func pluginNativeStack(_ stack: GGStack, project: ProjectConfig, remote: CodeHostRemote, worktree: Worktree,
                                   actionsAllowed: Bool) async throws -> NativeStack {
        let entries = try await stack.entries.sorted { $0.position < $1.position }.asyncMap { entry in
            NativeStackEntry(id: entry.id, sha: try await GitService().resolveRevision(at: worktree.path, ref: entry.sha),
                             position: entry.position, number: entry.prNumber, title: entry.title, state: entry.prState?.rawValue)
        }
        let unintegrated = stack.unintegratedCommits ?? []
        let unintegratedReason = "Resolve unintegrated work in native gg before using inbox mutation actions. "
            + unintegrated.map { "\($0.count) commit(s) after entry \($0.sitsOnPosition), latest \($0.sha): \($0.subject)" }.joined(separator: "; ")
        let complete = unintegrated.isEmpty && !entries.isEmpty && entries.count == stack.totalCommits && entries.count <= 500
            && Set(entries.map(\.position)) == Set(1...entries.count) && Set(entries.map(\.id)).count == entries.count
            && entries.allSatisfy { !$0.id.isEmpty && $0.number.map { $0 > 0 } == true }
            && Set(entries.compactMap(\.number)).count == entries.count
            && stack.entries.allSatisfy { $0.ggId?.isEmpty == false }
        var actions: [NativeStackAction] = [.open]
        var reasons: [String: String] = [:]
        if !unintegrated.isEmpty { reasons["sync"] = unintegratedReason; reasons["rebase"] = unintegratedReason }
        else if actionsAllowed { actions += [.sync, .rebase] }
        else { reasons["sync"] = "This worktree's native gg policy is inactive."; reasons["rebase"] = reasons["sync"] }
        if complete, actionsAllowed, GGAvailability.shared.capabilities.landJSONL, GGAvailability.shared.capabilities.clientOperationID {
            actions += [.land, .landThrough]
        } else {
            let reason = !unintegrated.isEmpty ? unintegratedReason
                : !complete ? "Some stack entries are unpublished or their review identities are unavailable. Sync and refresh before landing."
                : !actionsAllowed ? "This worktree's native gg policy is inactive." : "Update gg to support streaming landing and native operation identifiers."
            reasons["land"] = reason; reasons["landThrough"] = reason
        }
        return NativeStack(id: pluginStackID(project.id, stack.name), name: stack.name, base: stack.base, host: remote.host,
                           repo: remote.repositorySlug, worktree: worktree.id, complete: complete, entries: entries, actions: actions,
                           unavailableActions: reasons.isEmpty ? nil : reasons)
    }

    func openPluginStack(_ request: PluginStackOpenParams, projectID: String) async -> String? {
        // The host refreshed immediately before calling. Resolve the same cached scope, then verify the owning worktree.
        let inventory = await pluginStackInventory(projectID: projectID, refresh: false)
        do {
            let resolved = try request.resolve(in: inventory)
            guard let project = projects.first(where: { $0.id == projectID }), project.host == nil else { return "This project is unavailable." }
            guard let worktreeID = resolved.stack.worktree else {
                return presentPluginStackFollow(request, stack: resolved.stack, project: project)
            }
            guard let worktree = projectsManager.worktrees(projectId: projectID).first(where: { $0.id == worktreeID }) else {
                return "The stack's worktree is no longer available. Refresh and try again."
            }
            focusGlobalWorktree(id: worktree.id, projectId: projectID)
            let pane = rightPaneStore.state(for: worktree, baseBranch: config.worktrees.baseBranch, comparisonMode: config.changes.comparisonMode)
            pane.activePluginPanel = nil
            pane.activeTab = .changes
            config.rightPaneVisible = true
            if request.action == .open {
                Task { await pane.refresh() }
                return nil
            }
            let snapshot = try await pane.ggService.currentStackSnapshot(worktreePath: worktree.path.path, requireRemoteRefresh: true)
            guard let stack = snapshot.stack, let remote = try await projectStackRemote(project),
                  try await pluginNativeStack(stack, project: project, remote: remote, worktree: worktree, actionsAllowed: true).fingerprint == request.fingerprint else {
                return "The stack changed. Refresh and try again."
            }
            switch request.action {
            case .land, .landThrough:
                guard let target = resolved.entry, pane.pendingGGLand == nil else { return "A native stack confirmation is already open." }
                var prepared = try pane.ggMutationCoordinator.prepare(.land(target: target.id), using: snapshot)
                prepared.expectedFullMembers = resolved.stack.entries.map { .init(id: $0.id, sha: $0.sha, position: $0.position, number: $0.number) }
                pane.pendingGGLandPrepared = prepared
                pane.pendingGGLand = .until(entryId: target.id, title: target.title)
                pane.pendingGGPluginLandScope = resolved.stack.entries.filter { $0.position <= target.position && $0.state != "merged" }.map {
                    "\($0.position). #\($0.number.map(String.init) ?? "?") \($0.title)"
                }.joined(separator: "\n")
                return nil
            case .sync, .rebase:
                let mutation: GGMutationRequest = request.action == .sync ? .sync : .rebase(target: nil)
                var prepared = try pane.ggMutationCoordinator.prepare(mutation, using: snapshot)
                prepared.expectedFullMembers = resolved.stack.entries.map { .init(id: $0.id, sha: $0.sha, position: $0.position, number: $0.number) }
                return presentPluginStackConfirmation(title: request.action == .sync ? "Sync stack?" : "Rebase stack?",
                                                      message: "\(stack.name)\n\(resolved.stack.entries.map { "\($0.position). \($0.title)" }.joined(separator: "\n"))") { [weak self, weak pane] in
                    guard let self, let pane else { return }
                    do {
                        _ = try request.resolve(in: await self.pluginStackInventory(projectID: projectID, refresh: true))
                        pane.runGGMutation(prepared)
                    } catch { pane.ggActionState.setError(error.localizedDescription) }
                }
            case .open: return nil
            }
        } catch { return error.localizedDescription }
    }

    private func projectStackRemote(_ project: ProjectConfig) async throws -> CodeHostRemote? {
        CodeHostRemoteDetector.detect(from: try await GitService().remotes(worktreePath: URL(fileURLWithPath: project.path)))
    }

    private func presentPluginStackFollow(_ request: PluginStackOpenParams, stack: NativeStack, project: ProjectConfig) -> String? {
        guard request.action == .open else { return "Open the stack's native worktree first." }
        guard !GGProjectMutationGate.shared.isBusy(project: project.id) else { return "A project mutation is already running." }
        return presentPluginStackConfirmation(title: "Open stack worktree?",
                                              message: "Create or reuse the gg worktree for \(stack.name).\n\(stack.entries.map { "\($0.position). \($0.title)" }.joined(separator: "\n"))") { [weak self] in
            guard let self else { return }
            let gate = GGProjectMutationGate.shared
            let owner = "native-follow:\(UUID().uuidString)"
            do {
                guard let current = self.projects.first(where: { $0.id == project.id }), current == project,
                      let token = gate.acquire(project: project.id, owner: owner) else { throw PluginStackError("A project mutation is already running or the project changed.") }
                defer { gate.release(project: project.id, owner: owner, token: token) }
                let refreshed = await self.pluginStackInventory(projectID: project.id, refresh: true)
                guard refreshed.complete else { throw PluginStackError(refreshed.error ?? "Stack inventory is incomplete. Refresh before following this stack.") }
                _ = try request.resolve(in: refreshed)
                try Task.checkCancellation()
                try await GGService().followExistingStack(repoPath: project.path, name: stack.name, clientOperationID: "alas:\(UUID().uuidString)")
                await self.refreshProjectTopology(projectId: project.id)
                let candidates = self.projectsManager.worktrees(projectId: project.id)
                var matches: [Worktree] = []
                for worktree in candidates where !worktree.path.isRemoteAlasPath {
                    if let snapshot = try? await GGService().currentStackSnapshot(worktreePath: worktree.path.path, refreshRemote: false), snapshot.stack?.name == stack.name {
                        matches.append(worktree)
                    }
                }
                guard matches.count == 1, let worktree = matches.first else { throw PluginStackError("The stack was followed, but its registered worktree could not be resolved uniquely. Refresh native worktrees.") }
                self.focusGlobalWorktree(id: worktree.id, projectId: project.id)
                let pane = self.rightPaneStore.state(for: worktree, baseBranch: self.config.worktrees.baseBranch, comparisonMode: self.config.changes.comparisonMode)
                pane.activePluginPanel = nil
                pane.activeTab = .changes
                self.config.rightPaneVisible = true
                await pane.refresh()
            } catch { self.presentPluginStackFailure(error.localizedDescription) }
        }
    }

    /// AppKit owns the confirmation callback. No plugin message can invoke it.
    private func presentPluginStackConfirmation(title: String, message: String, confirm: @escaping @MainActor () async -> Void) -> String? {
        guard let window = NSApp.keyWindow, window.attachedSheet == nil else { return "Close the current native dialog and try again." }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor in await confirm() }
        }
        return nil
    }

    private func presentPluginStackFailure(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Stack action stopped"
        alert.informativeText = message
        if let window = NSApp.keyWindow, window.attachedSheet == nil { alert.beginSheetModal(for: window) }
    }
}

private extension Array {
    @MainActor
    func asyncMap<T>(_ transform: @MainActor (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        for element in self { result.append(try await transform(element)) }
        return result
    }
}
