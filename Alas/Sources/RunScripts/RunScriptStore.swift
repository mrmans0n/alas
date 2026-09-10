import Foundation

/// Stateless discovery of run scripts. Callers rescan on every menu/palette
/// open — the directories hold at most a handful of small files, so a fresh
/// scan is cheaper and simpler than watching them.
enum RunScriptStore {
    static let repoScriptsRelativeDir = ".alas/scripts"
    /// Only this many leading bytes are read for metadata parsing.
    private static let headerReadLimit = 4096

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
        guard let remoteHost else {
            return scripts(worktreeRoot: worktreeRoot, globalDir: globalDir)
        }
        return await remoteRepoScripts(worktreeRoot: worktreeRoot, host: remoteHost)
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

    private static func remoteRepoScripts(worktreeRoot: URL, host: String) async -> [RunScript] {
        let directory = repoScriptsDir(worktreeRoot: worktreeRoot)
        guard let entries = try? await RemoteFileStats.directoryEntries(
            host: host,
            worktreeRoot: worktreeRoot.path,
            path: directory.path
        ) else { return [] }

        var scripts: [RunScript] = []
        for entry in entries where !entry.isDirectory && !entry.name.hasPrefix(".") {
            let url = directory.appendingPathComponent(entry.name)
            guard case .file(let data, _) = try? await RemoteFileAccess.read(host: host, path: url.path) else {
                continue
            }
            let header = String(decoding: data.prefix(headerReadLimit), as: UTF8.self)
            let isExecutable = await isRemoteExecutable(host: host, path: url.path)
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

    private static func isRemoteExecutable(host: String, path: String) async -> Bool {
        let command = "test -x \(SSHCommand.shellQuote(path))"
        guard let result = try? await RemoteExec.run(host: host, cwd: nil, command: command, timeout: 5) else {
            return false
        }
        return result.exitCode == 0
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
