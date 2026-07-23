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
                let meta = RunScriptMetadata.parse(fileName: url.lastPathComponent, contents: headText(of: url))
                return RunScript(
                    scope: scope,
                    fileName: url.lastPathComponent,
                    fileURL: url,
                    displayName: meta.displayName,
                    onExit: meta.onExit,
                    cwd: meta.cwd,
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
}
