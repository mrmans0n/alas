import AlasPlatform
import Foundation

/// A simulator as simslim reports it. https://github.com/MobAI-App/simslim
public struct SimulatorSlimState: Equatable, Sendable {
    /// simslim's managed background services that are off, of `services`.
    public var servicesOff: Int
    public var services: Int
    /// False on runtimes before iOS 18.5, where slimming lasts until the simulator restarts.
    public var persistent: Bool
    public var memoryBytes: Int64?
    public var processes: Int?

    public init(servicesOff: Int, services: Int, persistent: Bool, memoryBytes: Int64?, processes: Int?) {
        self.servicesOff = servicesOff
        self.services = services
        self.persistent = persistent
        self.memoryBytes = memoryBytes
        self.processes = processes
    }

    public var isSlim: Bool { servicesOff > 0 }

    /// What `device_set_slim` returns.
    public var json: [String: Any] {
        var json: [String: Any] = ["slim": isSlim, "services_off": servicesOff, "services": services, "persistent": persistent]
        if let memoryBytes { json["memory_mb"] = Int((Double(memoryBytes) / 1_048_576).rounded()) }
        return json
    }
}

public enum SimulatorSlimError: Error, Equatable, LocalizedError {
    case notInstalled
    /// simslim's own reason.
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled: "simslim isn't installed."
        case .failed(let reason): reason
        }
    }
}

/// Runs simslim, which turns off the background services a simulator
/// doesn't need. The user installs it, from the simulator settings or Homebrew.
public enum SimulatorSlim {
    public static let formula = "mobai-app/tap/simslim"
    public static let installCommand = "brew install \(formula)"
    /// Kept on: push tokens (apsd) and universal links (swcd).
    public static let keptCategories = ["store", "web"]

    /// From `status --json` and `measure --json`; memory is left out when `measure` is unreadable.
    public static func state(status: Data, measure: Data?) throws -> SimulatorSlimState {
        struct Status: Decodable {
            let managedDisabled: Int
            let managedTotal: Int
            let persistent: Bool
        }
        struct Measure: Decodable {
            let processes: Int
            let bytes: Int64
        }
        guard let read = try? JSONDecoder().decode(Status.self, from: status) else {
            throw SimulatorSlimError.failed("simslim status answered something Alas can't read.")
        }
        let memory = measure.flatMap { try? JSONDecoder().decode(Measure.self, from: $0) }
        return SimulatorSlimState(
            servicesOff: read.managedDisabled, services: read.managedTotal, persistent: read.persistent,
            memoryBytes: memory?.bytes, processes: memory?.processes
        )
    }

    /// Every category id in `profiles --json`, in order.
    public static func categories(_ profiles: Data) throws -> [String] {
        struct Category: Decodable { let id: String }
        guard let read = try? JSONDecoder().decode([Category].self, from: profiles) else {
            throw SimulatorSlimError.failed("simslim profiles answered something Alas can't read.")
        }
        return read.map(\.id)
    }

    /// simslim ends a failure with `simslim: <reason>` on stderr.
    public static func failure(stderr: String, exitCode: Int32) -> SimulatorSlimError {
        let prefix = "simslim: "
        let line = stderr.split(whereSeparator: \.isNewline).last { $0.hasPrefix(prefix) }
        return .failed(line.map { String($0.dropFirst(prefix.count)) } ?? "simslim exited with status \(exitCode)")
    }

    /// A booted simulator's state; simslim can't read a shut-down one.
    public static func state(simslim: String, udid: String) async throws -> SimulatorSlimState {
        let status = try await run(simslim, ["status", udid, "--json"])
        let measure = try? await run(simslim, ["measure", udid, "--json"])
        return try state(status: Data(status.utf8), measure: measure.map { Data($0.utf8) })
    }

    /// Slims a booted simulator, or brings every service back, without a reboot; then reads it back.
    public static func set(simslim: String, udid: String, on: Bool) async throws -> SimulatorSlimState {
        if on {
            _ = try await run(simslim, ["on", udid, "--no-reboot", "--except", keptCategories.joined(separator: ",")], timeout: 180)
        } else {
            let all = try categories(Data(try await run(simslim, ["profiles", "--json"]).utf8))
            _ = try await run(simslim, ["enable", udid, all.joined(separator: ",")], timeout: 180)
        }
        return try await state(simslim: simslim, udid: udid)
    }

    private static func run(_ simslim: String, _ args: [String], timeout: TimeInterval = 30) async throws -> String {
        let result = try await Process.run(simslim, args: args, timeout: timeout)
        guard result.exitCode == 0 else { throw failure(stderr: result.stderr, exitCode: result.exitCode) }
        return result.stdout
    }
}
