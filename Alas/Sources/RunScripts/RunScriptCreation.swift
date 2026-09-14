import Foundation

struct RunScriptCreationPresentation: Identifiable, Equatable {
    let id: UUID
    let scope: RunScriptScope
    let projectId: String
    let worktreeId: String
    let repositoryName: String
    /// Stacks found at the worktree root when the dialog was requested.
    /// Always empty for global scripts, which are repository-agnostic.
    let detectedStacks: [RunScriptStackDetection]

    init(
        id: UUID = UUID(),
        scope: RunScriptScope,
        projectId: String,
        worktreeId: String,
        repositoryName: String,
        detectedStacks: [RunScriptStackDetection] = []
    ) {
        self.id = id
        self.scope = scope
        self.projectId = projectId
        self.worktreeId = worktreeId
        self.repositoryName = repositoryName
        self.detectedStacks = detectedStacks
    }

    var subtitle: String {
        switch scope {
        case .repo:
            "Create a script in .alas/scripts/ for \(repositoryName)."
        case .global:
            "Create a script available in every local worktree."
        }
    }
}

enum RunScriptCreationError: LocalizedError, Equatable {
    case emptyName
    case fileExists(String)
    case worktreeUnavailable
    case emptySelection
    case allScriptsExist

    var errorDescription: String? {
        switch self {
        case .emptyName:
            "Enter a script name."
        case .fileExists(let fileName):
            "A script named \"\(fileName)\" already exists."
        case .worktreeUnavailable:
            "The originating worktree is no longer available."
        case .emptySelection:
            "Choose at least one script."
        case .allScriptsExist:
            "All of the selected scripts already exist."
        }
    }
}

struct RunScriptBundleResult: Equatable {
    var created: [URL] = []
    var skipped: [URL] = []
}

enum RunScriptCreator {
    static func normalizedName(_ rawName: String) -> String? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    static func directory(
        scope: RunScriptScope,
        worktreeRoot: URL,
        globalDir: URL = Paths.runScriptsGlobalDir
    ) -> URL {
        scope == .repo ? RunScriptStore.repoScriptsDir(worktreeRoot: worktreeRoot) : globalDir
    }

    static func create(
        scope: RunScriptScope,
        name rawName: String,
        onExit: RunScriptOnExit,
        body: String? = nil,
        endpoint: String? = nil,
        worktreeRoot: URL,
        globalDir: URL = Paths.runScriptsGlobalDir,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let name = normalizedName(rawName) else {
            throw RunScriptCreationError.emptyName
        }
        let directory = directory(scope: scope, worktreeRoot: worktreeRoot, globalDir: globalDir)
        let url = directory.appendingPathComponent(RunScriptTemplate.fileName(for: name))

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        guard !fileManager.fileExists(atPath: url.path) else {
            throw RunScriptCreationError.fileExists(url.lastPathComponent)
        }
        let data = Data(RunScriptTemplate.contents(name: name, onExit: onExit, body: body, endpoint: endpoint).utf8)
        try data.write(to: url, options: .withoutOverwriting)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// Writes one script per action, each with the exit behavior and endpoint
    /// its template declares. A file that already exists is left untouched
    /// and reported as skipped rather than aborting the bundle — re-running a
    /// template must never clobber a script the user edited.
    static func createBundle(
        scope: RunScriptScope,
        actions: [RunScriptStackAction],
        worktreeRoot: URL,
        globalDir: URL = Paths.runScriptsGlobalDir,
        fileManager: FileManager = .default
    ) throws -> RunScriptBundleResult {
        guard !actions.isEmpty else { throw RunScriptCreationError.emptySelection }
        var result = RunScriptBundleResult()
        for action in actions {
            do {
                result.created.append(try create(
                    scope: scope,
                    name: action.displayName,
                    onExit: action.onExit,
                    body: action.body,
                    endpoint: action.endpoint,
                    worktreeRoot: worktreeRoot,
                    globalDir: globalDir,
                    fileManager: fileManager
                ))
            } catch RunScriptCreationError.fileExists(let fileName) {
                result.skipped.append(
                    directory(scope: scope, worktreeRoot: worktreeRoot, globalDir: globalDir)
                        .appendingPathComponent(fileName)
                )
            }
        }
        guard !result.created.isEmpty else { throw RunScriptCreationError.allScriptsExist }
        return result
    }
}
