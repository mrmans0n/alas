import Foundation

struct RunScriptCreationPresentation: Identifiable, Equatable {
    let id: UUID
    let scope: RunScriptScope
    let projectId: String
    let worktreeId: String
    let repositoryName: String

    init(
        id: UUID = UUID(),
        scope: RunScriptScope,
        projectId: String,
        worktreeId: String,
        repositoryName: String
    ) {
        self.id = id
        self.scope = scope
        self.projectId = projectId
        self.worktreeId = worktreeId
        self.repositoryName = repositoryName
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

    var errorDescription: String? {
        switch self {
        case .emptyName:
            "Enter a script name."
        case .fileExists(let fileName):
            "A script named \"\(fileName)\" already exists."
        case .worktreeUnavailable:
            "The originating worktree is no longer available."
        }
    }
}

enum RunScriptCreator {
    static func normalizedName(_ rawName: String) -> String? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    static func create(
        scope: RunScriptScope,
        name rawName: String,
        onExit: RunScriptOnExit,
        worktreeRoot: URL,
        globalDir: URL = Paths.runScriptsGlobalDir,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let name = normalizedName(rawName) else {
            throw RunScriptCreationError.emptyName
        }
        let directory = scope == .repo
            ? RunScriptStore.repoScriptsDir(worktreeRoot: worktreeRoot)
            : globalDir
        let url = directory.appendingPathComponent(RunScriptTemplate.fileName(for: name))

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        guard !fileManager.fileExists(atPath: url.path) else {
            throw RunScriptCreationError.fileExists(url.lastPathComponent)
        }
        let data = Data(RunScriptTemplate.contents(name: name, onExit: onExit).utf8)
        try data.write(to: url, options: .withoutOverwriting)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
