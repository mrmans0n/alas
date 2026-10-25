import AlasCore
import Foundation

/// A repository on `main` with one commit and a run script, made once per
/// test process and copied into each test that needs one, rather than each
/// running `git init` and committing.
enum GitTemplate {
    private static let template: URL = {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("alas-git-template-\(UUID().uuidString)")
        let scripts = repo.appendingPathComponent(".alas/scripts")
        try! FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let script = scripts.appendingPathComponent("hello.sh")
        try! "#!/bin/sh\necho hello from run\n".write(to: script, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        for arguments in [
            ["init", "-q", "-b", "main"],
            ["add", "."],
            ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-q", "-m", "initial"],
        ] {
            let git = Process()
            git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            git.arguments = arguments
            git.currentDirectoryURL = repo
            try! git.run()
            git.waitUntilExit()
            precondition(git.terminationStatus == 0, "git \(arguments.joined(separator: " ")) failed")
        }
        return repo
    }()

    /// A copy of the template at `destination`, whose parent must exist.
    ///
    /// Copied, and the template made, on a thread of its own: most callers
    /// are main-actor tests, and blocking the main actor starves every other
    /// main-actor suite running in parallel past its `eventually` deadline.
    static func repository(at destination: URL) async throws {
        try await BlockingWork.run { try FileManager.default.copyItem(at: template, to: destination) }
    }

    /// The template with three more commits on `main` that `origin/main`
    /// lacks, as a gg stack nothing has landed from: `origin` is a copy of
    /// the template, so every copy of this fetches the same base. The three
    /// SHAs, bottom-up.
    private static let aheadOfOrigin: (repo: URL, shas: [String]) = {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-git-ahead-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let origin = root.appendingPathComponent("origin")
        let repo = root.appendingPathComponent("repo")
        try! FileManager.default.copyItem(at: template, to: origin)
        try! FileManager.default.copyItem(at: template, to: repo)
        run(["remote", "add", "origin", origin.path], in: repo)
        run(["fetch", "-q", "origin", "main"], in: repo)
        for index in 1...3 {
            run(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-q", "--allow-empty", "-m", "entry \(index)"], in: repo)
        }
        let shas = run(["rev-list", "--reverse", "origin/main..HEAD"], in: repo).split(separator: "\n").map(String.init)
        return (repo, shas)
    }()

    /// A copy of the ahead-of-origin repository at `destination`, whose
    /// parent must exist; returns its three unlanded commits, bottom-up.
    static func repositoryAheadOfOrigin(at destination: URL) async throws -> [String] {
        try await BlockingWork.run {
            try FileManager.default.copyItem(at: aheadOfOrigin.repo, to: destination)
            return aheadOfOrigin.shas
        }
    }

    @discardableResult
    private static func run(_ arguments: [String], in repo: URL) -> String {
        let git = Process()
        let output = Pipe()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = arguments
        git.currentDirectoryURL = repo
        git.standardOutput = output
        try! git.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        git.waitUntilExit()
        precondition(git.terminationStatus == 0, "git \(arguments.joined(separator: " ")) failed")
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
