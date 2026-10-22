import AlasCore
import Foundation
import Synchronization

/// A command's failure, printed as is.
struct HostCommandError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Runs `launchctl` with `arguments`, its output discarded, and returns its status.
@discardableResult
func launchctl(_ arguments: String...) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return -1 }
    process.waitUntilExit()
    return process.terminationStatus
}

/// The `config`, `peers`, `project`, `restart` and `setup` commands. The project operations
/// go through the running host's socket when one serves the profile, and
/// through a host booted in this process when none does.
@MainActor
enum HostCommands {
    /// Runs the command `arguments` names and exits; returns when they name
    /// none of these commands.
    static func runIfCommand(_ arguments: [String]) {
        guard let command = arguments.first, ["config", "peers", "project", "registry", "restart", "setup"].contains(command) else { return }
        Task { @MainActor in
            do {
                try await run(command, Array(arguments.dropFirst()))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("alas-host: \(message(for: error))\n".utf8))
                exit(1)
            }
        }
        dispatchMain()
    }

    private static func run(_ command: String, _ arguments: [String]) async throws {
        switch (command, arguments.first, arguments.count) {
        case ("config", "list", 1), ("config", "get", 1):
            let config = readConfig()
            for (index, section) in HostSettingSection.allCases.enumerated() {
                print(index == 0 ? "# \(section.title)" : "\n# \(section.title)")
                for setting in HostSettingCatalog.all(for: config) where setting.section == section {
                    print("\(setting.key) = \(setting.value(in: config))")
                }
            }
        case ("config", "get", 2):
            let config = readConfig()
            print(try HostSettingCatalog.named(arguments[1], in: config).value(in: config))
        case ("config", "set", 3), ("config", "set", 4) where arguments.last == "--restart":
            let holder = try writableHolder()
            try HostProfileWrite.update { config in
                try HostSettingCatalog.named(arguments[1], in: config).set(arguments[2], in: &config)
            }
            if case .host = holder {
                if arguments.count == 4 { try restart(afterSaving: true) } else { print("Saved. Restart the host to apply: alas-host restart") }
            }
        case ("project", "list", 1):
            for project in try await listProjects() {
                print("\(project.id)  \(project.name)  \(project.path)")
            }
        case ("project", "add", 2), ("project", "add", 4) where arguments[2] == "--name":
            let project = try await addProject(path: arguments[1], name: arguments.count == 4 ? arguments[3] : nil)
            print(project.id)
        case ("project", "remove", 2):
            try await removeProject(arguments[1])
        case ("peers", "list", 1):
            for peer in try await listPeers() {
                print("\(peer.id)  \(peer.name)  \(peer.serverId)")
            }
        case ("peers", "remove", 2):
            let query = arguments[1]
            guard let peer = try await listPeers().first(where: { [$0.id, $0.name, $0.serverId].contains(query) }) else {
                throw HostCommandError("No paired Mac has the id, name or server id \(query).")
            }
            try await forgetPeer(peer.id)
        case ("registry", "search", 1), ("registry", "search", 2):
            let query = arguments.count == 2 ? arguments[1] : ""
            let installed = readConfig().agents.registry
            let registry = try await ACPRegistryClient().agents()
            let matches = { (id: String, name: String) in
                query.isEmpty || id.localizedCaseInsensitiveContains(query) || name.localizedCaseInsensitiveContains(query)
            }
            for agent in registry where matches(agent.id, agent.name) {
                let note = switch ACPRegistryEntryStatus.resolve(agent: agent, installed: installed) {
                case .builtin(let agentID): "  (built in: agents.\(agentID).enabled)"
                case .installed: "  (installed)"
                case .updateAvailable(let version): "  (installed \(version); install updates it)"
                case .unsupported: "  (no build for this Mac)"
                case .notInstalled: ""
                }
                print("\(agent.id)  \(agent.name)  \(agent.version)\(note)")
            }
            // Installed agents the registry no longer lists, which only
            // `registry uninstall` removes now.
            for agent in ACPRegistryInstalledAgent.unlisted(installed, registry: registry)
                where matches(agent.registryID, agent.displayName) {
                print("\(agent.registryID)  \(agent.displayName)  \(agent.version)  (installed; no longer in the registry)")
            }
        case ("registry", "install", 2):
            // Fail early, before the download; the write below asks again.
            _ = try writableHolder()
            guard let agent = try await ACPRegistryClient().agents().first(where: { $0.id == arguments[1] }) else {
                throw HostCommandError("The ACP registry has no agent \(arguments[1]); see alas-host registry search.")
            }
            // As the app's registry browser: built-ins and agents without a
            // build for this Mac are not installed from the registry.
            switch ACPRegistryEntryStatus.resolve(agent: agent, installed: readConfig().agents.registry) {
            case .builtin(let agentID):
                throw HostCommandError("\(agent.name) ships with Alas; turn it on or off with agents.\(agentID).enabled.")
            case .unsupported:
                throw HostCommandError("\(agent.name) has no build for this Mac.")
            case .installed:
                print("\(agent.name) \(agent.version) is already installed.")
                return
            case .notInstalled, .updateAvailable:
                break
            }
            // The download can take a while, and who holds the profile may
            // have changed since: ask again before the new files replace any
            // installed ones, and hold that, its lock included, while writing.
            let checked = Mutex<DataDirectoryHolder?>(nil)
            let installed = try await ACPRegistryInstaller().install(agent) {
                let holder = try writableHolder()
                checked.withLock { $0 = holder }
            }
            let writer = try checked.withLock { $0 } ?? writableHolder()
            try withExtendedLifetime(writer) {
                try HostProfileWrite.update { $0.agents.installRegistryAgent(installed) }
            }
            print("Installed \(agent.name) \(agent.version) as agents.\(agent.id).enabled.")
            if case .host = writer { print("Restart the host to use it: alas-host restart") }
        case ("registry", "uninstall", 2):
            let holder = try writableHolder()
            guard let record = readConfig().agents.registry.first(where: { $0.registryID == arguments[1] }) else {
                throw HostCommandError("No agent \(arguments[1]) is installed from the ACP registry.")
            }
            // The record goes first, while the holder just checked still
            // holds: removing a large npm install can take long enough for
            // the app to open the profile in between. Files that fail to go
            // get their record back, so a later uninstall still finds them.
            try withExtendedLifetime(holder) {
                try HostProfileWrite.update { $0.agents.uninstallRegistryAgent(registryID: arguments[1]) }
                do {
                    try ACPRegistryInstaller().uninstall(registryID: arguments[1])
                } catch {
                    try? HostProfileWrite.update { $0.agents.installRegistryAgent(record) }
                    throw error
                }
            }
            print("Uninstalled \(arguments[1]).")
            if case .host = holder { print("Restart the host to apply: alas-host restart") }
        case ("restart", nil, 0):
            try restart()
        case ("setup", nil, 0):
            try await HostSetup.run()
        default:
            throw HostCommandError("unknown command \(([command] + arguments).joined(separator: " "))\n\(usage)")
        }
    }

    static func message(for error: any Error) -> String {
        switch error as? HostError {
        case .projectBusy?: "A session or run is live in one of the project's worktrees; stop it and run this again."
        case .operationInProgress?: "Another operation is underway in one of the project's worktrees."
        case .notFound(let what)?: "Not found: \(what)."
        case .project(let error)?: error.localizedDescription
        case .failed(let message)?: message
        case let error?: "\(error)"
        case nil: error.localizedDescription
        }
    }

    static func readConfig() -> AppConfig {
        (try? PersistenceStore().readIfExists(AppConfig.self, from: Paths.appConfigFile)) ?? .defaults
    }

    /// Who holds the profile, for a command that writes it: the app and an
    /// unknown process keep it in memory and would overwrite the change.
    nonisolated static func writableHolder() throws -> DataDirectoryHolder {
        let holder = DataDirectoryHolder.current()
        switch holder {
        case .app: throw HostProfileRefusal()
        case .unknown(let pid):
            throw HostCommandError("Another process \(pid.map { "(pid \($0)) " } ?? "")holds this profile; stop it and run this again.")
        case .none, .host: return holder
        }
    }

    // MARK: - Projects

    /// The profile's projects, as its file lists them: the host saves every
    /// change before answering it.
    static func listProjects() async throws -> [ProjectSnapshot] {
        let file = try PersistenceStore().readIfExists(ProjectsFile.self, from: Paths.projectsFile)
        return (file?.projects ?? []).map(ProjectSnapshot.init)
    }

    /// Adds the git work tree or folder at `path`, named `name` or after its folder.
    static func addProject(path: String, name: String?) async throws -> ProjectSnapshot {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let kind: ProjectKind = (try? await GitService().isGitRepository(url)) == true ? .git : .folder
        let name = name ?? url.lastPathComponent
        return try await perform(.addProject(path: url.path, displayName: name, host: nil, kind: kind)) {
            if case .project(let project) = $0 { project } else { nil }
        } inProcess: { host in
            try await host.projects.add(path: url, displayName: name, icon: .default(), kind: kind, caller: .localUser(uid: getuid()))
        }
    }

    /// Removes the project whose id or path is `idOrPath`.
    static func removeProject(_ idOrPath: String) async throws {
        let path = URL(fileURLWithPath: idOrPath).standardizedFileURL.path
        guard let project = try await listProjects().first(where: { $0.id == idOrPath || $0.path == path }) else {
            throw HostCommandError("No project has the id or path \(idOrPath).")
        }
        try await perform(.removeProject(projectID: project.id)) { $0 == .done ? () : nil } inProcess: { host in
            try await host.projects.remove(projectID: project.id, caller: .localUser(uid: getuid()))
        }
    }

    // MARK: - Peers

    /// The Macs paired with this host. Booted in process, no host serves them,
    /// so the files are read and written here, under the lock `perform` holds.
    static func listPeers() async throws -> [HostPeerSummary] {
        try await perform(.listPeers) {
            if case .peers(let peers) = $0 { peers } else { nil }
        } inProcess: { _ in
            localPeerManager().peers.map { HostPeerSummary(id: $0.id, serverId: $0.serverId, name: $0.name, origins: $0.origins) }
        }
    }

    static func forgetPeer(_ id: String) async throws {
        try await perform(.forgetPeer(peerID: id)) { $0 == .done ? () : nil } inProcess: { _ in
            // The pairing service's revoke persists the device revocation.
            localPeerManager().forget(peerId: id)
        }
    }

    private static func localPeerManager() -> RemotePeerManager {
        RemotePeerManager(
            store: FilePeerStore(secrets: RemoteHostSecretStore()),
            pairing: RemotePairingService(store: FileDeviceStore()),
            localIdentity: { .init(serverId: "", name: "", origins: []) }
        )
    }

    /// Sends `request` to the running host, or runs `inProcess` on a host
    /// booted here while this process holds the profile.
    private static func perform<T>(
        _ request: HostRequest, decode: (HostResponse) -> T?, inProcess: (AlasHost) async throws -> T
    ) async throws -> T {
        switch try writableHolder() {
        case .host:
            let response: HostResponse
            do {
                response = try HostSocketServer.request(request)
            } catch {
                throw HostCommandError("no host serves \(HostSocketServer.defaultPath()): \(error.localizedDescription)")
            }
            if case .failure(let error) = response { throw error }
            guard let result = decode(response) else { throw HostCommandError("the host answered \(response)") }
            return result
        case .none(let lock):
            defer { withExtendedLifetime(lock) {} }
            let host = try AlasHost.boot()
            do {
                let result = try await inProcess(host)
                await host.shutdown()
                return result
            } catch {
                await host.shutdown()
                throw error
            }
        case .app, .unknown:
            fatalError("refused by writableHolder()")
        }
    }

    // MARK: - Restart

    /// Restarts the launch agent's host. `afterSaving`, a host run in a
    /// terminal is no failure: the settings are saved, and it says how to apply them.
    static func restart(afterSaving: Bool = false) throws {
        let agent = HostLaunchAgent(executable: URL(fileURLWithPath: CommandLine.arguments[0]))
        let service = "gui/\(getuid())/\(agent.label)"
        if FileManager.default.fileExists(atPath: agent.plistURL.path), launchctl("print", service) == 0 {
            guard launchctl("kickstart", "-k", service) == 0 else {
                throw HostCommandError("launchctl could not restart \(agent.label)")
            }
            print("Restarted.")
            return
        }
        switch DataDirectoryHolder.current() {
        case .host where afterSaving:
            print("Saved. The host is not running as a launch agent; stop it (Ctrl-C) and start it again to apply.")
        case .host, .unknown:
            throw HostCommandError("The host is not running as a launch agent; stop it (Ctrl-C) and start it again.")
        case .none, .app:
            print("No host is running.")
        }
    }
}
