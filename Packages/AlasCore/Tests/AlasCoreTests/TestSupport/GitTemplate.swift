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
    static func repository(at destination: URL) throws {
        try FileManager.default.copyItem(at: template, to: destination)
    }
}
