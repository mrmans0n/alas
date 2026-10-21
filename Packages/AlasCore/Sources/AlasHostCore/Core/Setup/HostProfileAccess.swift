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
    public static func update(
        _ change: (inout AppConfig) throws -> Void,
        file: URL = Paths.appConfigFile,
        store: PersistenceStore = .init()
    ) throws {
        var config = try store.readIfExists(AppConfig.self, from: file) ?? .defaults
        try change(&config)
        try store.write(config, to: file)
    }
}
