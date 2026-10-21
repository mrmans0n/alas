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

    /// Applies the `before` -> `after` change to `base`: only values that differ between
    /// `before` and `after` are written (objects merge recursively, and so do arrays of
    /// objects with an identity key), keys `change` cleared are removed, and everything
    /// else in `base` keeps its raw value.
    static func apply(from before: [String: Any], to after: [String: Any], onto base: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in after {
            if let nested = value as? [String: Any], let baseNested = base[key] as? [String: Any] {
                result[key] = apply(from: before[key] as? [String: Any] ?? [:], to: nested, onto: baseNested)
            } else if before[key].map({ ($0 as AnyObject).isEqual(value) }) != true {
                result[key] = (value as? [Any]).flatMap { array in
                    (base[key] as? [Any]).flatMap { apply(from: before[key] as? [Any] ?? [], to: array, onto: $0) }
                } ?? value
            }
        }
        for key in before.keys where after[key] == nil {
            result[key] = nil
        }
        return result
    }

    /// Merges arrays whose elements are all objects with a unique identity
    /// (`registryID` for installed registry agents, else `id`) element by element:
    /// matching elements merge like objects, elements `change` added are appended,
    /// ones it removed are dropped, and the rest of `base` stays. Nil when the
    /// elements have no such identity, so the whole array is replaced.
    private static func apply(from before: [Any], to after: [Any], onto base: [Any]) -> [Any]? {
        for key in ["registryID", "id"] {
            guard let before = keyed(before, by: key), let after = keyed(after, by: key), let base = keyed(base, by: key)
            else { continue }
            let old = Dictionary(uniqueKeysWithValues: before)
            let new = Dictionary(uniqueKeysWithValues: after)
            let baseIDs = Set(base.map(\.id))
            let kept: [Any] = base.compactMap { id, object in
                guard let next = new[id] else { return old[id] == nil ? object : nil }
                return apply(from: old[id] ?? [:], to: next, onto: object)
            }
            return kept + after.filter { !baseIDs.contains($0.id) }.map(\.object)
        }
        return nil
    }

    private static func keyed(_ array: [Any], by key: String) -> [(id: String, object: [String: Any])]? {
        let keyed = array.compactMap { element -> (id: String, object: [String: Any])? in
            guard let object = element as? [String: Any], let id = object[key] as? String else { return nil }
            return (id, object)
        }
        return keyed.count == array.count && Set(keyed.map(\.id)).count == keyed.count ? keyed : nil
    }
}
