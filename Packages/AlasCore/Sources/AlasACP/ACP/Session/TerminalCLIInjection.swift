import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

public enum TerminalCLIInjection: Sendable {
    public static let executableName = "alas"
    public static let aoExecutableName = "ao"
    private static let fallbackPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    /// The per-architecture directory the app bundles the CLI under.
    public static var archDirectory: String {
        #if arch(arm64)
        "macos-aarch64"
        #else
        "macos-x86_64"
        #endif
    }

    /// The bundled `alas` binary slice for the running architecture, or nil if
    /// it isn't present (e.g. unit tests running outside the app bundle).
    public static func bundledBinaryURL() -> URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let url = resourceURL.appendingPathComponent("alas-cli/\(archDirectory)/alas")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// Copies the bundled `alas` binary into Alas's managed bin dir under both
    /// `alas` and `ao`, and returns that directory. `ao` is the same binary
    /// (it dispatches on argv[0]). Copies are atomic, `0o755`, and only
    /// rewritten when the destination bytes differ from the source. Callers
    /// prepend the returned dir to the session PATH.
    @discardableResult
    public static func installExecutables(sourceBinary: URL? = nil) throws -> URL {
        let dir = Paths.appSupportRoot.appendingPathComponent("bin", isDirectory: true)
        try Paths.ensureDirectoryExists(dir)
        guard let source = sourceBinary ?? bundledBinaryURL() else {
            throw CocoaError(.fileNoSuchFile)
        }
        try installBinary(from: source, named: executableName, into: dir)
        try installBinary(from: source, named: aoExecutableName, into: dir)
        return dir
    }

    private static func installBinary(from source: URL, named name: String, into dir: URL) throws {
        let dest = dir.appendingPathComponent(name, isDirectory: false)
        let sourceData = try Data(contentsOf: source)
        let destData = try? Data(contentsOf: dest)
        if destData != sourceData {
            try sourceData.write(to: dest, options: .atomic)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
    }

    public static func pathValue(prepending directory: String, to current: String?) -> String {
        let basePath = current?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? current!
            : fallbackPath
        return "\(directory):\(basePath)"
    }
}
