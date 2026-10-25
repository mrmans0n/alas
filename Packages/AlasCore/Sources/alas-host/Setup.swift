import AlasCore
import Foundation

/// `alas-host setup`: runs `HostSetupModel` in the terminal and carries out
/// its effects. Changes go to the profile's file when saved; projects change
/// at once, through the running host when one serves the profile.
@MainActor
enum HostSetup {
    static func run() async throws {
        guard Terminal.isInteractive else { throw HostCommandError("setup needs a terminal") }
        // Refused while the app or an unknown process holds the profile. A
        // lock taken here is let go at once: the project commands take it
        // themselves, and saving checks again.
        _ = try HostCommands.writableHolder()
        let config = HostCommands.readConfig()
        var model = HostSetupModel(
            config: config, projects: try await HostCommands.listProjects(), missingCommands: await missingAdapterCommands(config)
        )

        // Said first: the check runs gh and glab, which can stall offline.
        print("Checking gh/glab sign-in…")
        model.notice = await codeHostSignInNotice(model.projects)

        Terminal.enter()
        defer { Terminal.restore() }
        while true {
            Terminal.draw(model.view, notice: model.notice)
            guard let key = Terminal.readKey() else { continue }
            switch model.handle(key) {
            case nil:
                break
            case .quit:
                return
            case .save:
                do {
                    let holder = try HostCommands.writableHolder()
                    try HostProfileWrite.update { try model.applyChanges(to: &$0) }
                    model.markSaved()
                    guard case .host = holder else {
                        Terminal.restore()
                        print("Saved.")
                        return
                    }
                } catch {
                    model.notice = "Not saved: \(HostCommands.message(for: error))"
                    continue
                }
                let now = askToRestart()
                Terminal.restore()
                if now {
                    try HostCommands.restart(afterSaving: true)
                } else {
                    print("Saved. Restart the host to apply: alas-host restart")
                }
                return
            case .addProject(let path):
                do {
                    let project = try await HostCommands.addProject(path: path, name: nil)
                    model.projects = try await HostCommands.listProjects()
                    model.notice = "Added \(project.name)."
                } catch {
                    model.notice = HostCommands.message(for: error)
                }
            case .removeProject(let id):
                do {
                    try await HostCommands.removeProject(id)
                    model.projects = try await HostCommands.listProjects()
                    model.notice = "Removed."
                } catch {
                    model.notice = HostCommands.message(for: error)
                }
            case .showPairingCode:
                model.notice = pairingNotice(reachability: model.original.hostReachability)
            }
        }
    }

    /// The adapter command of each agent whose command is not found the way
    /// the host launches it: the login shell's PATH, then this process's,
    /// plus the well-known directories.
    private static func missingAdapterCommands(_ config: AppConfig) async -> [String: String] {
        ShellEnvResolver.shared.resolve()
        await ShellEnvResolver.shared.waitUntilResolved()
        let path = ACPProcessEnvironment.baseEnvironment()["PATH"]
        return HostSetupModel.missingAdapterCommands(config) { AgentPath.resolveExecutable(named: $0, base: path) != nil }
    }

    /// What to do for each code host a local project's remote uses whose CLI is
    /// missing or signed out; shepherds and `pr_create` need it. Nil when none.
    private static func codeHostSignInNotice(_ projects: [ProjectSnapshot]) async -> String? {
        var checked: [CodeHostKind: String?] = [:]
        for project in projects where project.host == nil && project.kind != .folder {
            let url = URL(fileURLWithPath: project.path)
            guard let remotes = try? await GitService().remotes(worktreePath: url),
                let remote = CodeHostRemoteDetector.detect(from: remotes),
                checked[remote.kind] == nil,
                let provider = CodeHostProviderRegistry.live().provider(for: remote.kind)
            else { continue }
            if !(await provider.isAvailable(cwd: url)) {
                checked[remote.kind] = .some(AlasCoreContext.prProviderSetupMessage(kind: remote.kind, isInstalled: false))
            } else if !(await provider.isAuthenticated(remote: remote, cwd: url)) {
                checked[remote.kind] = .some(AlasCoreContext.prProviderSetupMessage(kind: remote.kind, isInstalled: true))
            } else {
                checked[remote.kind] = .some(nil)
            }
        }
        let messages = checked.sorted { $0.key.rawValue < $1.key.rawValue }.compactMap { $0.value ?? nil }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    /// Asks whether to restart the running host now; Escape means later.
    private static func askToRestart() -> Bool {
        var selected = 1
        while true {
            Terminal.draw(
                HostSetupView(
                    title: "Restart the host now? This ends running sessions and runs. [now / later]",
                    rows: ["now", "later"], selected: selected, hint: "Up/Down to choose, Enter to confirm"
                ),
                notice: nil
            )
            switch Terminal.readKey() {
            case .up?, .character("n")?: selected = 0
            case .down?, .tab?, .character("l")?: selected = 1
            case .enter?: return selected == 0
            case .escape?: return false
            default: break
            }
        }
    }

    /// A pairing code from the running host, or how to get one.
    private static func pairingNotice(reachability: HostReachability) -> String {
        guard let response = try? HostSocketServer.request(.remotePairingCode) else {
            return "Start the host, then pair with: alas-host pair"
        }
        switch response {
        case .remotePairingCode(let code, let expiresAt, _):
            var notice = "Pairing code: \(code) (valid until \(expiresAt.formatted(date: .omitted, time: .standard)))"
            if reachability == .loopback {
                notice += "\nThis host listens on loopback only: phones reach it through an SSH tunnel or Tailscale."
            }
            return notice
        case .failure(let error):
            return HostCommands.message(for: error)
        default:
            return "The host does not mint Remote pairing codes."
        }
    }
}
