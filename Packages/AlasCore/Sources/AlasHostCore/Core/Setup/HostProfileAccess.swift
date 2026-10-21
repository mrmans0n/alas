import AlasFoundation
import AlasModel
import Darwin
import Foundation

/// Who has the data directory, as far as a setup command needs to know.
public enum DataDirectoryHolder: Sendable {
    /// Nobody; the acquired lock is released by dropping it.
    case none(DataDirectoryLock)
    case host(pid: Int32)
    case app(pid: Int32?)
    case unknown(pid: Int32?)

    public static func current() -> DataDirectoryHolder {
        do {
            return .none(try DataDirectoryLock.acquire())
        } catch DataDirectoryLock.Refusal.held(let pid) {
            return classify(executableName: pid.flatMap(executableName(of:)), pid: pid)
        } catch {
            return .unknown(pid: nil)
        }
    }

    static func classify(executableName: String?, pid: Int32?) -> DataDirectoryHolder {
        switch (executableName, pid) {
        case ("alas-host", let pid?): .host(pid: pid)
        case ("Alas", _): .app(pid: pid)
        default: .unknown(pid: pid)
        }
    }

    private static func executableName(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).lastPathComponent
    }
}

public struct HostProfileRefusal: LocalizedError {
    public init() {}
    public var errorDescription: String? {
        "The Alas app has this profile open. Change settings in its Settings window, or quit it and run this again."
    }
}

public enum HostProfileWrite {
    /// Reads the profile (defaults when absent), applies `change`, writes it back.
    /// Only what `change` touched is rewritten: keys this build does not model
    /// (a newer app's settings, values it cannot decode) stay as they were.
    public static func update(
        _ change: (inout AppConfig) throws -> Void,
        file: URL = Paths.appConfigFile,
        store: PersistenceStore = .init()
    ) throws {
        let raw = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        var config = try store.readIfExists(AppConfig.self, from: file) ?? .defaults
        let before = try jsonObject(store.encode(config))
        try change(&config)
        let after = try jsonObject(store.encode(config))
        let merged = apply(from: before, to: after, onto: raw)
        try store.write(
            data: JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
            to: file
        )
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    /// Applies the `before` -> `after` change to `base`: every value `after` holds wins
    /// (objects merge recursively), keys `change` cleared are removed, the rest of `base` stays.
    static func apply(from before: [String: Any], to after: [String: Any], onto base: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in after {
            if let nested = value as? [String: Any], let baseNested = base[key] as? [String: Any] {
                result[key] = apply(from: before[key] as? [String: Any] ?? [:], to: nested, onto: baseNested)
            } else {
                result[key] = value
            }
        }
        for key in before.keys where after[key] == nil {
            result[key] = nil
        }
        return result
    }
}
