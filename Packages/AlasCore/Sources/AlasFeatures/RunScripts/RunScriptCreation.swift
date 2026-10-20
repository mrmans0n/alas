import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform

public struct RunScriptCreationPresentation: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let scope: RunScriptScope
    public let projectId: String
    public let worktreeId: String
    public let repositoryName: String
    /// Stacks found at the worktree root when the dialog was requested.
    /// Always empty for global scripts, which are repository-agnostic.
    public let detectedStacks: [RunScriptStackDetection]

    public init(
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

    public var subtitle: String {
        switch scope {
        case .repo:
            "Create a script in .alas/scripts/ for \(repositoryName)."
        case .global:
            "Create a script available in every local worktree."
        }
    }
}

public enum RunScriptCreationError: LocalizedError, Equatable, Sendable {
    case emptyName
    case fileExists(String)
    case worktreeUnavailable
    case emptySelection
    case allScriptsExist

    public var errorDescription: String? {
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

public struct RunScriptBundleResult: Equatable, Sendable {
    public var created: [URL] = []
    public var skipped: [URL] = []

    public init(created: [URL] = [], skipped: [URL] = []) {
        self.created = created
        self.skipped = skipped
    }
}

public enum RunScriptCreator: Sendable {
    public static func normalizedName(_ rawName: String) -> String? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    public static func directory(
        scope: RunScriptScope,
        worktreeRoot: URL,
        globalDir: URL = Paths.runScriptsGlobalDir
    ) -> URL {
        scope == .repo ? RunScriptStore.repoScriptsDir(worktreeRoot: worktreeRoot) : globalDir
    }

    public static func create(
        scope: RunScriptScope,
        name rawName: String,
        onExit: RunScriptOnExit,
        body: String? = nil,
        endpoint: String? = nil,
        /// Overrides the slugified-name filename. Stack bundles use this to
        /// namespace by stack, so two stacks whose actions share a display
        /// name (e.g. "Build") never collide on disk.
        fileName fileNameOverride: String? = nil,
        worktreeRoot: URL,
        globalDir: URL = Paths.runScriptsGlobalDir,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let name = normalizedName(rawName) else {
            throw RunScriptCreationError.emptyName
        }
        let directory = directory(scope: scope, worktreeRoot: worktreeRoot, globalDir: globalDir)
        let fileName = fileNameOverride ?? RunScriptTemplate.fileName(for: name)
        let url = directory.appendingPathComponent(fileName)

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
    ///
    /// Filenames are namespaced by stack (`cargo-build.sh`, not `build.sh`) so
    /// bootstrapping two stacks in the same repository — a Cargo/JS hybrid,
    /// say — never has one stack's "Build" silently skip another's. The
    /// display name gets the same treatment ("Build (Cargo)"), since the
    /// toolbar and palette render only that name and "Build" would otherwise
    /// be ambiguous between two stacks' scripts.
    public static func createBundle(
        scope: RunScriptScope,
        stack: RunScriptStack,
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
                    name: "\(action.displayName) (\(stack.displayName))",
                    onExit: action.onExit,
                    body: action.body,
                    endpoint: action.endpoint,
                    fileName: "\(stack.fileSlug)-\(action.id).sh",
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
