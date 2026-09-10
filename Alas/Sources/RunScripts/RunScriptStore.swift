import Foundation

/// Stateless discovery of run scripts. Callers rescan on every menu/palette
/// open — the directories hold at most a handful of small files, so a fresh
/// scan is cheaper and simpler than watching them.
enum RunScriptStore {
    static let repoScriptsRelativeDir = ".alas/scripts"
    /// Only this many leading bytes are read for metadata parsing.
    private static let headerReadLimit = 4096

    enum DiscoveryResult {
        case scripts([RunScript])
        case failed(String)
    }

    enum RemoteProbeError: LocalizedError {
        case executableProbeFailed(path: String, status: Int32)

        var errorDescription: String? {
            switch self {
            case let .executableProbeFailed(path, status):
                "Could not determine whether remote script is executable: \(path) (exit \(status))"
            }
        }
    }

    static func repoScriptsDir(worktreeRoot: URL) -> URL {
        worktreeRoot.appendingPathComponent(repoScriptsRelativeDir, isDirectory: true)
    }

    /// Repo scripts first, then global, each sorted by display name.
    static func scripts(
        worktreeRoot: URL,
        globalDir: URL = Paths.runScriptsGlobalDir
    ) -> [RunScript] {
        discover(in: repoScriptsDir(worktreeRoot: worktreeRoot), scope: .repo)
            + discover(in: globalDir, scope: .global)
    }

    /// Host-aware discovery for UI surfaces attached to a concrete worktree.
    /// Local worktrees keep the synchronous FileManager path; remote worktrees
    /// scan repository scripts through SSH so the list matches what launches.
    static func scripts(
        worktreeRoot: URL,
        remoteHost: String?,
        globalDir: URL = Paths.runScriptsGlobalDir
    ) async -> [RunScript] {
        switch await discoverScripts(worktreeRoot: worktreeRoot, remoteHost: remoteHost, globalDir: globalDir) {
        case .scripts(let scripts): scripts
        case .failed: []
        }
    }

    static func discoverScripts(
        worktreeRoot: URL,
        remoteHost: String?,
        globalDir: URL = Paths.runScriptsGlobalDir
    ) async -> DiscoveryResult {
        guard let remoteHost else {
            return .scripts(scripts(worktreeRoot: worktreeRoot, globalDir: globalDir))
        }
        do {
            return .scripts(try await remoteRepoScripts(worktreeRoot: worktreeRoot, host: remoteHost))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func discover(in dir: URL, scope: RunScriptScope) -> [RunScript] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map { url in
                script(
                    scope: scope,
                    fileName: url.lastPathComponent,
                    fileURL: url,
                    contents: headText(of: url),
                    isExecutable: fm.isExecutableFile(atPath: url.path)
                )
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private static func headText(of url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: headerReadLimit)) ?? nil
        guard let data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func remoteRepoScripts(worktreeRoot: URL, host: String) async throws -> [RunScript] {
        let directory = repoScriptsDir(worktreeRoot: worktreeRoot)
        let entries = try await remoteRepoScriptEntries(host: host, worktreeRoot: worktreeRoot, directory: directory)

        var scripts: [RunScript] = []
        for entry in entries where !entry.isDirectory && !entry.name.hasPrefix(".") {
            let url = directory.appendingPathComponent(entry.name)
            guard let data = try await RemoteFileAccess.readPrefix(
                host: host,
                path: url.path,
                maxBytes: headerReadLimit
            ) else {
                continue
            }
            let header = String(decoding: data, as: UTF8.self)
            let isExecutable = try await isRemoteExecutable(host: host, path: url.path)
            scripts.append(script(
                scope: .repo,
                fileName: entry.name,
                fileURL: url,
                contents: header,
                isExecutable: isExecutable
            ))
        }
        return scripts.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private static func remoteRepoScriptEntries(
        host: String,
        worktreeRoot: URL,
        directory: URL
    ) async throws -> [(name: String, isDirectory: Bool)] {
        switch try await RemotePathContainment.containedList(
            host: host,
            path: directory.path,
            worktreeRoot: worktreeRoot.path
        ) {
        case .ok(let entries):
            return entries
        case .notADirectory:
            return []
        case .outsideWorktree:
            throw RemotePathContainment.ContainmentError.outsideWorktree(directory.path)
        case .unreadable:
            throw RemoteFileStatsError.directoryListingFailed(path: directory.path)
        }
    }

    private static func isRemoteExecutable(host: String, path: String) async throws -> Bool {
        let command = "test -x \(SSHCommand.shellQuote(path))"
        let result = try await RemoteExec.run(host: host, cwd: nil, command: command, timeout: 5)
        switch result.exitCode {
        case 0:
            return true
        case 1:
            return false
        default:
            throw RemoteProbeError.executableProbeFailed(path: path, status: result.exitCode)
        }
    }

    static func script(
        scope: RunScriptScope,
        fileName: String,
        fileURL: URL,
        contents: String,
        isExecutable: Bool
    ) -> RunScript {
        let meta = RunScriptMetadata.parse(fileName: fileName, contents: contents)
        return RunScript(
            scope: scope,
            fileName: fileName,
            fileURL: fileURL,
            displayName: meta.displayName,
            onExit: meta.onExit,
            cwd: meta.cwd,
            isExecutable: isExecutable,
            endpoint: meta.endpoint
        )
    }
}
