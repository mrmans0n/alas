import CryptoKit
import Foundation

enum ACPRegistryInstallError: LocalizedError, Equatable {
    case unsupportedPlatform(String)
    case invalidRegistryID(String)
    case checksumMismatch
    case invalidCommand(String)
    case missingExecutable(String)
    case missingNpmExecutable(String)
    case uvNotFound
    case commandFailed(String, status: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedPlatform(let name):
            return "\(name) has no macOS distribution in the ACP registry."
        case .invalidRegistryID(let id):
            return "`\(id)` is not a valid ACP registry agent id."
        case .checksumMismatch:
            return "The downloaded archive does not match the registry checksum."
        case .invalidCommand(let command):
            return "The registry command `\(command)` is not a path inside the agent archive."
        case .missingExecutable(let path):
            return "The agent archive does not contain an executable at `\(path)`."
        case .missingNpmExecutable(let package):
            return "npm package `\(package)` does not provide an executable."
        case .uvNotFound:
            return "Install uv to run this agent: `uvx` was not found on PATH."
        case .commandFailed(let command, let status, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "`\(command)` exited with status \(status)" + (detail.isEmpty ? "." : ": \(detail)")
        }
    }
}

/// Installs ACP registry agents into Alas-owned directories under `root`
/// (one per registry id) and returns the record to persist.
///
/// - binary: download, verify the optional SHA-256, extract, run `cmd`.
/// - npm: `npm install --prefix <dir> <package>`, run the package's bin.
/// - uv: nothing to install; `uvx` fetches the pinned package on launch.
///
/// Each install is staged next to its destination and swapped in only after
/// it produced an executable, so a failed update keeps the working install.
struct ACPRegistryInstaller: Sendable {
    typealias Download = @Sendable (URL) async throws -> URL
    typealias Runner = @Sendable (_ command: String, _ args: [String]) async throws -> (status: Int32, stderr: String)

    let root: URL
    let platform: String
    let download: Download
    let runner: Runner
    let findExecutable: @Sendable (String) -> String?

    init(
        root: URL = Paths.acpRegistryAgentsDirectory,
        platform: String = ACPRegistryPlatform.current,
        download: @escaping Download = { try await ACPRegistryInstaller.defaultDownload($0) },
        runner: @escaping Runner = ClaudeCodeACPInstaller.defaultRunner,
        findExecutable: @escaping @Sendable (String) -> String? = {
            AgentPath.resolveExecutable(named: $0, base: ProcessInfo.processInfo.environment["PATH"])
        }
    ) {
        self.root = root
        self.platform = platform
        self.download = download
        self.runner = runner
        self.findExecutable = findExecutable
    }

    func install(_ agent: ACPRegistryAgent) async throws -> ACPRegistryInstalledAgent {
        // Validate before any filesystem work: the id names the install directory.
        _ = try installDirectory(registryID: agent.id)
        guard let plan = agent.installPlan(platform: platform) else {
            throw ACPRegistryInstallError.unsupportedPlatform(agent.name)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let command: String
        let arguments: [String]
        let environment: [String: String]
        switch plan {
        case .binary(let target):
            command = try await installBinary(target, registryID: agent.id)
            arguments = target.args ?? []
            environment = target.env ?? [:]
        case .npm(let package):
            command = try await installNpm(package, registryID: agent.id)
            arguments = package.args ?? []
            environment = package.env ?? [:]
        case .uvx(let package):
            guard findExecutable("uvx") != nil else { throw ACPRegistryInstallError.uvNotFound }
            try uninstall(registryID: agent.id)
            command = "uvx"
            arguments = [package.package] + (package.args ?? [])
            environment = package.env ?? [:]
        }
        return ACPRegistryInstalledAgent(
            registryID: agent.id,
            displayName: agent.name,
            version: agent.version,
            command: command,
            arguments: arguments,
            environment: environment,
            isEnabled: true
        )
    }

    func uninstall(registryID: String) throws {
        let directory = try installDirectory(registryID: registryID)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    /// The agent's directory under `root`. Throws unless `registryID` matches
    /// the registry schema (`^[a-z][a-z0-9-]*$`), so a hostile entry cannot
    /// name a path outside `root`.
    func installDirectory(registryID: String) throws -> URL {
        guard Self.isValidRegistryID(registryID) else {
            throw ACPRegistryInstallError.invalidRegistryID(registryID)
        }
        return root.appendingPathComponent(registryID, isDirectory: true)
    }

    static func isValidRegistryID(_ id: String) -> Bool {
        guard let first = id.unicodeScalars.first, ("a"..."z").contains(first) else { return false }
        return id.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    // MARK: - Distributions

    private func installBinary(_ target: ACPRegistryAgent.BinaryTarget, registryID: String) async throws -> String {
        let relative = try Self.relativeCommandPath(target.cmd)
        return try await installStaged(registryID: registryID) { staging in
            let archive = try await download(target.archive)
            defer { try? FileManager.default.removeItem(at: archive) }
            if let expected = target.sha256,
               try Self.sha256Hex(of: archive) != expected.lowercased() {
                throw ACPRegistryInstallError.checksumMismatch
            }
            let executable = staging.appendingPathComponent(relative)
            if Self.isArchive(target.archive) {
                try await run("tar", ["-xf", archive.path, "-C", staging.path])
            } else {
                try FileManager.default.createDirectory(
                    at: executable.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.copyItem(at: archive, to: executable)
            }
            try Self.makeExecutable(executable, relativePath: relative)
            return relative
        }
    }

    private func installNpm(_ package: ACPRegistryAgent.Package, registryID: String) async throws -> String {
        let name = Self.npmPackageName(fromSpec: package.package)
        return try await installStaged(registryID: registryID) { staging in
            try await run("npm", [
                "install", "--prefix", staging.path,
                "--no-audit", "--no-fund", "--loglevel=error",
                package.package,
            ])
            let manifest = staging.appendingPathComponent("node_modules/\(name)/package.json")
            guard let data = try? Data(contentsOf: manifest) else {
                throw ACPRegistryInstallError.missingNpmExecutable(name)
            }
            let bin = try Self.npmExecutableName(manifest: data, packageName: name)
            let relative = "node_modules/.bin/\(bin)"
            guard FileManager.default.isExecutableFile(atPath: staging.appendingPathComponent(relative).path) else {
                throw ACPRegistryInstallError.missingNpmExecutable(name)
            }
            return relative
        }
    }

    /// Runs `populate` in a fresh staging directory, then swaps it into the
    /// agent's install directory. `populate` returns the executable's path
    /// relative to the directory; the result is its final absolute path.
    private func installStaged(
        registryID: String,
        populate: (URL) async throws -> String
    ) async throws -> String {
        let fm = FileManager.default
        let staging = root.appendingPathComponent(".staging-\(registryID)-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        var promoted = false
        defer { if !promoted { try? fm.removeItem(at: staging) } }
        let relative = try await populate(staging)
        let destination = try installDirectory(registryID: registryID)
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: destination)
        }
        promoted = true
        return destination.appendingPathComponent(relative).path
    }

    private func run(_ command: String, _ args: [String]) async throws {
        let (status, stderr) = try await runner(command, args)
        if status != 0 {
            throw ACPRegistryInstallError.commandFailed(command, status: status, stderr: stderr)
        }
    }

    // MARK: - Pure helpers

    /// The registry `cmd` as a path inside the extracted archive. Rejects
    /// absolute paths and `..` so an entry cannot point outside its install.
    static func relativeCommandPath(_ cmd: String) throws -> String {
        var path = cmd.trimmingCharacters(in: .whitespaces)
        while path.hasPrefix("./") { path.removeFirst(2) }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty,
              !path.hasPrefix("/"),
              !path.hasPrefix("~"),
              !components.contains(where: { $0 == ".." || $0 == "." }) else {
            throw ACPRegistryInstallError.invalidCommand(cmd)
        }
        return components.joined(separator: "/")
    }

    /// `@scope/name@1.2.3` → `@scope/name`; `name@1.2.3` → `name`.
    static func npmPackageName(fromSpec spec: String) -> String {
        let searchStart = spec.hasPrefix("@") ? spec.index(after: spec.startIndex) : spec.startIndex
        guard let versionAt = spec[searchStart...].firstIndex(of: "@") else { return spec }
        return String(spec[..<versionAt])
    }

    /// The executable npx would run for `packageName`: its only bin, or the
    /// bin named after the unscoped package name.
    static func npmExecutableName(manifest: Data, packageName: String) throws -> String {
        let unscoped = packageName.split(separator: "/").last.map(String.init) ?? packageName
        let json = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any]
        switch json?["bin"] {
        case is String:
            return unscoped
        case let bins as [String: Any]:
            if bins.count == 1, let only = bins.keys.first { return only }
            if bins[unscoped] != nil { return unscoped }
        default:
            break
        }
        throw ACPRegistryInstallError.missingNpmExecutable(packageName)
    }

    static func isArchive(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return [".zip", ".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tar.xz", ".txz", ".tar"]
            .contains { name.hasSuffix($0) }
    }

    static func sha256Hex(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func makeExecutable(_ file: URL, relativePath: String) throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw ACPRegistryInstallError.missingExecutable(relativePath)
        }
        if !fm.isExecutableFile(atPath: file.path) {
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
    }

    static func defaultDownload(_ url: URL) async throws -> URL {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("Alas", forHTTPHeaderField: "User-Agent")
        let (location, response) = try await URLSession.shared.download(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: location)
            throw URLError(.badServerResponse)
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-acp-\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: location, to: destination)
        return destination
    }
}
