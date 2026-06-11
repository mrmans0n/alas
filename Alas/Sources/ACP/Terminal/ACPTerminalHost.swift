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

    private(set) var sessionCwd: String
    private(set) var sessionEnv: [String: String]
    @Published private(set) var terminals: [String: ACPTerminal] = [:]

    init(sessionCwd: String, sessionEnv: [String: String]) {
        self.sessionCwd = sessionCwd
        self.sessionEnv = sessionEnv
    }

    /// UI lookup: returns released terminals too, so a tool card can keep
    /// rendering the captured output after the agent calls `terminal/release`.
    func terminal(id: String) -> ACPTerminal? { terminals[id] }

    /// Protocol lookup: returns nil for released terminals so callers
    /// surface a `notFound` to the agent. Matches the ACP rule that a
    /// released id can no longer be used with `terminal/*` methods.
    private func liveTerminal(_ id: String) -> ACPTerminal? {
        guard let term = terminals[id], !term.released else { return nil }
        return term
    }

    func create(_ p: ACPTerminalCreateParams) throws -> ACPTerminalCreateResult {
        let liveCount = terminals.values.filter { $0.exitStatus == nil }.count
        if liveCount >= Self.maxLiveTerminals {
            throw ACPTerminalHostError.tooManyTerminals
        }
        let id = UUID().uuidString.lowercased()
        let cwd = resolveCwd(p.cwd)
        let env = mergedEnv(p.env)
        let limit = p.outputByteLimit ?? 65_536
        do {
            let term = try ACPTerminal(
                id: id,
                command: p.command,
                args: p.args ?? [],
                env: env,
                cwd: cwd,
                outputByteLimit: limit)
            term.onExit = { [weak self] in
                self?.pruneFinishedTerminals()
            }
            terminals[id] = term
            return ACPTerminalCreateResult(terminalId: id)
        } catch {
            throw ACPTerminalHostError.spawnFailed(error.localizedDescription)
        }
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

    func updateContext(sessionCwd: String, sessionEnv: [String: String]) {
        self.sessionCwd = sessionCwd
        self.sessionEnv = sessionEnv
    }

    // MARK: - Helpers

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

    private func pruneFinishedTerminals() {
        let finished = terminals.values
            .filter { $0.exitStatus != nil }
            .sorted { $0.createdAt < $1.createdAt }
        let overflow = finished.count - Self.maxRetainedFinishedTerminals
        guard overflow > 0 else { return }
        for term in finished.prefix(overflow) {
            terminals.removeValue(forKey: term.id)
        }
    }
}
