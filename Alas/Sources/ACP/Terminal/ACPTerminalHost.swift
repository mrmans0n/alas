import Foundation

enum ACPTerminalHostError: Error, Equatable {
    case notFound(String)
    case tooManyTerminals
    case spawnFailed(String)
}

@MainActor
final class ACPTerminalHost: ObservableObject {
    static let maxLiveTerminals = 32
    static let maxRetainedFinishedTerminals = 64
    static let maxMetadataTerminals = 64

    private(set) var sessionCwd: String
    private(set) var sessionEnv: [String: String]
    private(set) var sessionRemoteHost: String?
    @Published private(set) var terminals: [String: ACPTerminal] = [:]

    init(sessionCwd: String, sessionEnv: [String: String], sessionRemoteHost: String? = nil) {
        self.sessionCwd = sessionCwd
        self.sessionEnv = sessionEnv
        self.sessionRemoteHost = sessionRemoteHost
    }

    /// UI lookup: returns released terminals too, so a tool card can keep
    /// rendering the captured output after the agent calls `terminal/release`.
    func terminal(id: String) -> ACPTerminal? { terminals[id] }

    /// Protocol lookup: returns nil for released terminals so callers
    /// surface a `notFound` to the agent. Matches the ACP rule that a
    /// released id can no longer be used with `terminal/*` methods.
    private func liveTerminal(_ id: String) -> ACPTerminal? {
        guard let term = terminals[id], !term.released, term.isProcessBacked else { return nil }
        return term
    }

    func create(_ p: ACPTerminalCreateParams) throws -> ACPTerminalCreateResult {
        let liveCount = terminals.values.filter { $0.isProcessBacked && $0.exitStatus == nil }.count
        if liveCount >= Self.maxLiveTerminals {
            throw ACPTerminalHostError.tooManyTerminals
        }
        let id = UUID().uuidString.lowercased()
        let cwd = resolveCwd(p.cwd)
        let env = mergedEnv(p.env)
        let limit = p.outputByteLimit ?? 65_536
        do {
            let term: ACPTerminal
            if let host = executionHost(forResolvedCwd: cwd) {
                let script = ACPRemoteLaunch.terminalCommand(command: p.command, args: p.args ?? [], env: agentRequestedEnv(p.env), cwd: cwd)
                let ssh = SSHCommand(host: host, mode: .batch)
                term = try ACPTerminal(id: id, command: SSHCommand.executable, args: ["-tt"] + ssh.argv(remoteScript: SSHCommand.remoteScript(command: script)), env: ProcessInfo.processInfo.environment, cwd: FileManager.default.temporaryDirectory.path, outputByteLimit: limit, normalizesCRLF: true)
            } else {
                term = try ACPTerminal(id: id, command: p.command, args: p.args ?? [], env: env, cwd: cwd, outputByteLimit: limit)
            }
            term.onExit = { [weak self] in
                self?.pruneFinishedTerminals()
            }
            terminals[id] = term
            return ACPTerminalCreateResult(terminalId: id)
        } catch {
            throw ACPTerminalHostError.spawnFailed(error.localizedDescription)
        }
    }

    func recordMetadataTerminalInfo(terminalId: String, cwd: String?) {
        _ = metadataTerminal(terminalId: terminalId, cwd: cwd)
    }

    func appendMetadataOutput(terminalId: String, data: Data, replace: Bool) {
        metadataTerminal(terminalId: terminalId, cwd: nil)
            .appendMetadataOutput(data, replace: replace)
    }

    func recordMetadataExit(terminalId: String, exitStatus: ACPTerminalExitStatus) {
        metadataTerminal(terminalId: terminalId, cwd: nil)
            .finishMetadata(exitStatus: exitStatus)
    }

    func output(_ p: ACPTerminalOutputParams) throws -> ACPTerminalOutputResult {
        guard let term = liveTerminal(p.terminalId) else {
            throw ACPTerminalHostError.notFound(p.terminalId)
        }
        let snap = term.snapshot(byteLimit: term.outputByteLimit)
        return ACPTerminalOutputResult(
            output: snap.text,
            truncated: snap.truncated,
            exitStatus: term.exitStatus)
    }

    func waitForExit(_ p: ACPTerminalIdParams) async throws -> ACPTerminalExitStatus {
        guard let term = liveTerminal(p.terminalId) else {
            throw ACPTerminalHostError.notFound(p.terminalId)
        }
        return await term.waitForExit()
    }

    func kill(_ p: ACPTerminalIdParams) throws {
        guard let term = liveTerminal(p.terminalId) else {
            throw ACPTerminalHostError.notFound(p.terminalId)
        }
        term.kill()
    }

    /// Per ACP spec: kills the command if still running and invalidates
    /// the id for subsequent `terminal/*` calls — but the entry stays
    /// in the registry so any tool card referencing it keeps rendering
    /// the captured output. `liveTerminal(_:)` enforces the invalidation.
    func release(_ p: ACPTerminalIdParams) throws {
        guard let term = liveTerminal(p.terminalId) else {
            throw ACPTerminalHostError.notFound(p.terminalId)
        }
        term.release()
    }

    /// Terminates every live terminal. Dictionary entries are intentionally
    /// retained so UI subscribers can render the post-mortem footer for
    /// tool cards that still reference these ids.
    func killAll() {
        for term in terminals.values { term.kill() }
    }

    var retainedByteEstimate: UInt64 {
        terminals.values.reduce(0) { $0 &+ UInt64($1.buffer.count) }
    }

    func updateContext(sessionCwd: String, sessionEnv: [String: String], sessionRemoteHost: String? = nil) {
        self.sessionCwd = sessionCwd
        self.sessionEnv = sessionEnv
        self.sessionRemoteHost = sessionRemoteHost
    }

    // MARK: - Helpers

    func executionHost(forResolvedCwd cwd: String) -> String? {
        sessionRemoteHost ?? RemoteHostRegistry.shared.host(forPath: cwd)
    }

    private func resolveCwd(_ requested: String?) -> String {
        guard let r = requested, !r.isEmpty else { return sessionCwd }
        return (r as NSString).isAbsolutePath
            ? r
            : (sessionCwd as NSString).appendingPathComponent(r)
    }

    private func mergedEnv(_ overlay: [ACPEnvVar]?) -> [String: String] {
        var out = sessionEnv
        for v in overlay ?? [] { out[v.name] = v.value }
        return out
    }

    func agentRequestedEnv(_ env: [ACPEnvVar]?) -> [String: String] {
        var out: [String: String] = [:]
        for v in env ?? [] {
            out[v.name] = v.value
        }
        return out
    }

    private func metadataTerminal(terminalId: String, cwd: String?) -> ACPTerminal {
        if let term = terminals[terminalId] {
            if cwd != nil { term.updateMetadataCwd(cwd) }
            return term
        }

        let term = ACPTerminal(
            metadataId: terminalId,
            cwd: cwd ?? sessionCwd,
            outputByteLimit: 65_536)
        term.onExit = { [weak self] in
            self?.pruneMetadataTerminals()
        }
        terminals[terminalId] = term
        pruneMetadataTerminals()
        return term
    }

    private func pruneFinishedTerminals() {
        let finished = terminals.values
            .filter { $0.isProcessBacked && $0.exitStatus != nil }
            .sorted { $0.createdAt < $1.createdAt }
        let overflow = finished.count - Self.maxRetainedFinishedTerminals
        guard overflow > 0 else { return }
        for term in finished.prefix(overflow) {
            terminals.removeValue(forKey: term.id)
        }
    }

    private func pruneMetadataTerminals() {
        let metadata = terminals.values
            .filter { !$0.isProcessBacked }
            .sorted { $0.createdAt < $1.createdAt }
        let overflow = metadata.count - Self.maxMetadataTerminals
        guard overflow > 0 else { return }
        for term in metadata.prefix(overflow) {
            terminals.removeValue(forKey: term.id)
        }
    }
}
