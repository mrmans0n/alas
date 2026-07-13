import Foundation

/// What a remote host offers, probed once per host per app run. Drives
/// BSD-vs-GNU tool choices and graceful degradation (`rg` fallback, zmx
/// availability, and the installed Alas helper handshake).
struct RemoteHostCapabilities: Equatable {
    enum OS: Equatable {
        case linux
        case macos
        case other
    }

    let os: OS
    let gitVersion: String?
    let hasRipgrep: Bool
    let hasZmx: Bool
    let helperHandshake: RemoteHelperHandshake?
    /// Normalized machine architecture (`arm64` is represented as `aarch64`).
    let arch: String?

    /// POSIX-portable probe; each line is independently parseable so a
    /// missing tool never shifts the others.
    static let probeCommand =
        "uname -s; git version 2>/dev/null; "
        + "command -v rg >/dev/null 2>&1 && echo rg=yes || echo rg=no; "
        + "(command -v zmx >/dev/null 2>&1 || [ -x \"$HOME/.alas/bin/zmx\" ]) && echo zmx=yes || echo zmx=no; "
        + "if [ -x \"$HOME/.alas/bin/alas-helper\" ]; then "
        + "helper_output=$(\"$HOME/.alas/bin/alas-helper\" version 2>/dev/null || true); "
        + "[ -n \"$helper_output\" ] && printf 'helper=%s\\n' \"$helper_output\" || echo helper=no; "
        + "else echo helper=no; fi; "
        + "echo \"arch=$(uname -m)\""

    static func parse(_ output: String) -> RemoteHostCapabilities {
        var os = OS.other
        var gitVersion: String?
        var hasRipgrep = false
        var hasZmx = false
        var helperHandshake: RemoteHelperHandshake?
        var arch: String?

        for line in output.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch line {
            case "Linux": os = .linux
            case "Darwin": os = .macos
            case "rg=yes": hasRipgrep = true
            case "zmx=yes": hasZmx = true
            default:
                if line.hasPrefix("git version ") {
                    gitVersion = line.dropFirst("git version ".count)
                        .split(separator: " ").first.map(String.init)
                } else if line.hasPrefix("arch=") {
                    let value = String(line.dropFirst("arch=".count))
                    guard !value.isEmpty else { continue }
                    arch = value == "arm64" ? "aarch64" : value
                } else if line.hasPrefix("helper=") {
                    helperHandshake = RemoteHelperHandshake.decode(String(line.dropFirst("helper=".count)))
                }
            }
        }

        return RemoteHostCapabilities(
            os: os,
            gitVersion: gitVersion,
            hasRipgrep: hasRipgrep,
            hasZmx: hasZmx,
            helperHandshake: helperHandshake,
            arch: arch
        )
    }
}

/// One probe per host per app run, cached. Connection failures are not
/// cached so a host that comes online later probes again.
final class RemoteHostCapabilityStore: @unchecked Sendable {
    static let shared = RemoteHostCapabilityStore()

    private let lock = NSLock()
    private var cache: [String: RemoteHostCapabilities] = [:]
    private var inFlight: [String: Task<RemoteHostCapabilities?, Never>] = [:]

    func capabilities(for host: String) async -> RemoteHostCapabilities? {
        lock.lock()
        if let cached = cache[host] {
            lock.unlock()
            return cached
        }
        if let running = inFlight[host] {
            lock.unlock()
            return await running.value
        }

        let task = Task<RemoteHostCapabilities?, Never> {
            guard let result = try? await RemoteExec.run(
                host: host,
                cwd: nil,
                command: RemoteHostCapabilities.probeCommand
            ), !RemoteExec.isConnectionFailure(exitCode: result.exitCode) else {
                return nil
            }
            return RemoteHostCapabilities.parse(result.stdout)
        }
        inFlight[host] = task
        lock.unlock()

        let capabilities = await task.value
        lock.lock()
        inFlight.removeValue(forKey: host)
        if let capabilities {
            cache[host] = capabilities
        }
        lock.unlock()
        return capabilities
    }

    func invalidate(host: String) {
        lock.lock()
        cache.removeValue(forKey: host)
        lock.unlock()
    }
}
