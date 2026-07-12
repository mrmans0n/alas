import Foundation

/// Spawns language servers on the remote host. The Content-Length-framed
/// LSP stream rides the ssh child's stdio exactly like the ACP channel;
/// `file://` URIs are correct on both sides because the server and the
/// files share the remote filesystem.
enum RemoteLSPLauncher {
    static func invocation(
        host: String,
        rootPath: String,
        command: String,
        args: [String],
        env: [String: String]
    ) -> RemoteExecInvocation {
        let prefix = sourceKitResolutionPrefix(command: command, env: env)
        let executable = prefix == nil ? SSHCommand.shellQuote(command) : "\"$resolved_lsp\""
        let argv = ([executable] + args.map(SSHCommand.shellQuote)).joined(separator: " ")
        let run: String
        if env.isEmpty {
            run = "\(prefix ?? "")exec \(argv)"
        } else {
            let pairs = env.sorted { $0.key < $1.key }
                .map { SSHCommand.shellQuote("\($0.key)=\($0.value)") }
                .joined(separator: " ")
            run = "\(prefix ?? "")exec env \(pairs) \(argv)"
        }
        return RemoteExec.invocation(host: host, cwd: rootPath, command: run)
    }

    private static let availabilityLock = NSLock()
    nonisolated(unsafe) private static var availability: [String: Bool] = [:]

    /// Cached `command -v` probe. Connection failures return false but are
    /// not cached, so a host that comes back online probes again.
    static func isAvailable(command: String, host: String, env: [String: String] = [:]) async -> Bool {
        let key = availabilityCacheKey(command: command, host: host, env: env)
        availabilityLock.lock()
        let cached = availability[key]
        availabilityLock.unlock()
        if let cached { return cached }

        guard let result = try? await RemoteExec.run(
            host: host,
            cwd: nil,
            command: availabilityProbeCommand(command: command, env: env),
            timeout: 10
        ), !RemoteExec.isConnectionFailure(exitCode: result.exitCode) else {
            return false
        }

        let available = result.exitCode == 0
        availabilityLock.lock()
        availability[key] = available
        availabilityLock.unlock()
        return available
    }

    static func availabilityProbeCommand(command: String, env: [String: String] = [:]) -> String {
        let probe: String
        if command == "sourcekit-lsp" {
            probe = "command -v 'sourcekit-lsp' >/dev/null 2>&1 || xcrun --find 'sourcekit-lsp' >/dev/null 2>&1"
        } else {
            probe = "command -v \(SSHCommand.shellQuote(command))"
        }
        guard !env.isEmpty else { return probe }
        return "env \(envAssignments(env)) sh -c \(SSHCommand.shellQuote(probe))"
    }

    private static func sourceKitResolutionPrefix(command: String, env: [String: String]) -> String? {
        guard command == "sourcekit-lsp" else { return nil }
        if !env.isEmpty {
            let resolver = #"command -v "$1" 2>/dev/null || xcrun --find "$1""#
            return "resolved_lsp=$(env \(envAssignments(env)) sh -c \(SSHCommand.shellQuote(resolver)) sh 'sourcekit-lsp') && "
        }
        return "resolved_lsp=$(command -v 'sourcekit-lsp' 2>/dev/null || xcrun --find 'sourcekit-lsp') && "
    }

    private static func availabilityCacheKey(command: String, host: String, env: [String: String]) -> String {
        ([host, command] + env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })
            .joined(separator: "\u{0}")
    }

    private static func envAssignments(_ env: [String: String]) -> String {
        env.sorted { $0.key < $1.key }
            .map { SSHCommand.shellQuote("\($0.key)=\($0.value)") }
            .joined(separator: " ")
    }
}
