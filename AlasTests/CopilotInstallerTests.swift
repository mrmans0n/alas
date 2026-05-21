import Foundation
import Testing
@testable import Alas

struct CopilotInstallerTests {
    private func tmpDir() -> (dir: URL, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, { try? FileManager.default.removeItem(at: dir) })
    }

    private func hookURL(in root: URL) -> URL {
        root
            .appendingPathComponent(".github", isDirectory: true)
            .appendingPathComponent("hooks", isDirectory: true)
            .appendingPathComponent("alas-notify.json", isDirectory: false)
    }

    private func installedJSON(in root: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: hookURL(in: root))) as! [String: Any]
    }

    @Test func installWritesManagedHookJSON() throws {
        let (dir, cleanup) = tmpDir()
        defer { cleanup() }

        try CopilotInstaller(projectRootURL: dir).install()

        let installed = try installedJSON(in: dir)
        #expect(installed["version"] as? Int == 1)
        #expect(installed["alas_marker"] as? String == "alas-managed-copilot-hook-v1")

        let hooks = installed["hooks"] as! [String: Any]
        let expectedEvents = [
            "agentStop": "idle",
            "permissionRequest": "permission_request",
            "sessionStart": "attached",
            "sessionEnd": "detached",
            "userPromptSubmitted": "busy",
            "preToolUse": "busy",
            "postToolUse": "busy",
            "postToolUseFailure": "busy",
        ]
        #expect(Set(hooks.keys) == Set(expectedEvents.keys))
        for (event, activity) in expectedEvents {
            let entries = hooks[event] as! [[String: Any]]
            #expect(entries.count == 1)
            #expect(entries[0]["type"] as? String == "command")
            #expect(entries[0]["timeoutSec"] as? Int == 5)
            let command = entries[0]["bash"] as! String
            #expect(command.contains(#""agent":"copilot""#))
            #expect(command.contains(#""event":"\#(activity)""#))
            #expect(command.contains("{}"))
            #expect(command.hasSuffix(AlasHookCommand.ownershipSentinel))
        }
    }

    @Test func installCreatesParentDirectories() throws {
        let (dir, cleanup) = tmpDir()
        defer { cleanup() }

        try CopilotInstaller(projectRootURL: dir).install()

        #expect(FileManager.default.fileExists(atPath: hookURL(in: dir).path))
    }

    @Test func installRejectsMissingProjectRootWithoutCreatingDirectories() throws {
        let (parent, cleanup) = tmpDir()
        defer { cleanup() }
        let missingRoot = parent.appendingPathComponent("missing-root", isDirectory: true)

        #expect(throws: CopilotInstallerError.self) {
            try CopilotInstaller(projectRootURL: missingRoot).install()
        }

        #expect(!FileManager.default.fileExists(atPath: missingRoot.path))
    }

    @Test func installRejectsProjectRootThatIsNotDirectory() throws {
        let (dir, cleanup) = tmpDir()
        defer { cleanup() }
        let fileURL = dir.appendingPathComponent("project-file")
        try "not a directory".write(to: fileURL, atomically: true, encoding: .utf8)

        #expect(throws: CopilotInstallerError.self) {
            try CopilotInstaller(projectRootURL: fileURL).install()
        }

        #expect(!FileManager.default.fileExists(atPath: hookURL(in: fileURL).path))
    }

    @Test func installAddsHookPathToGitInfoExcludeWhenGitInfoExists() throws {
        let (dir, cleanup) = tmpDir()
        defer { cleanup() }
        let infoURL = dir.appendingPathComponent(".git/info", isDirectory: true)
        try FileManager.default.createDirectory(at: infoURL, withIntermediateDirectories: true)
        let excludeURL = infoURL.appendingPathComponent("exclude")
        try "existing-pattern\n".write(to: excludeURL, atomically: true, encoding: .utf8)

        try CopilotInstaller(projectRootURL: dir).install()

        let exclude = try String(contentsOf: excludeURL, encoding: .utf8)
        #expect(exclude.contains("existing-pattern\n"))
        #expect(exclude.contains(".github/hooks/alas-notify.json\n"))
    }

    @Test func installAddsHookPathToLinkedWorktreeInfoExclude() throws {
        let (dir, cleanup) = tmpDir()
        defer { cleanup() }
        let mainGitDir = dir.appendingPathComponent("main-git-dir", isDirectory: true)
        let worktreeGitDir = mainGitDir
            .appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent("linked", isDirectory: true)
        let commonInfoURL = mainGitDir.appendingPathComponent("info", isDirectory: true)
        try FileManager.default.createDirectory(at: commonInfoURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktreeGitDir, withIntermediateDirectories: true)
        try "../..".write(
            to: worktreeGitDir.appendingPathComponent("commondir", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        try "gitdir: main-git-dir/worktrees/linked\n".write(
            to: dir.appendingPathComponent(".git", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        try CopilotInstaller(projectRootURL: dir).install()

        let excludeURL = commonInfoURL.appendingPathComponent("exclude", isDirectory: false)
        let exclude = try String(contentsOf: excludeURL, encoding: .utf8)
        #expect(exclude.contains(".github/hooks/alas-notify.json\n"))
        #expect(!FileManager.default.fileExists(
            atPath: worktreeGitDir.appendingPathComponent("info/exclude", isDirectory: false).path
        ))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git/info/exclude").path))
    }

    @Test func installPreservesExcludeWhenExistingExcludeCannotBeDecoded() throws {
        let (dir, cleanup) = tmpDir()
        defer { cleanup() }
        let infoURL = dir.appendingPathComponent(".git/info", isDirectory: true)
        try FileManager.default.createDirectory(at: infoURL, withIntermediateDirectories: true)
        let excludeURL = infoURL.appendingPathComponent("exclude")
        let invalidUTF8 = Data([0xff, 0xfe, 0xfd])
        try invalidUTF8.write(to: excludeURL)

        try CopilotInstaller(projectRootURL: dir).install()

        #expect(try Data(contentsOf: excludeURL) == invalidUTF8)
        #expect(FileManager.default.fileExists(atPath: hookURL(in: dir).path))
    }

    @Test func excludeUpdateIsIdempotent() throws {
        let (dir, cleanup) = tmpDir()
        defer { cleanup() }
        let infoURL = dir.appendingPathComponent(".git/info", isDirectory: true)
        try FileManager.default.createDirectory(at: infoURL, withIntermediateDirectories: true)

        let installer = CopilotInstaller(projectRootURL: dir)
        try installer.install()
        try installer.install()

        let excludeURL = infoURL.appendingPathComponent("exclude")
        let exclude = try String(contentsOf: excludeURL, encoding: .utf8)
        let occurrences = exclude.components(separatedBy: ".github/hooks/alas-notify.json").count - 1
        #expect(occurrences == 1)
    }

    @Test func installDoesNotCreateExcludeWhenGitInfoDoesNotExist() throws {
        let (dir, cleanup) = tmpDir()
        defer { cleanup() }

        try CopilotInstaller(projectRootURL: dir).install()

        let excludeURL = dir.appendingPathComponent(".git/info/exclude")
        #expect(!FileManager.default.fileExists(atPath: excludeURL.path))
    }

    @Test func installPreservesUnmanagedExistingHookFileAndThrows() throws {
        let (dir, cleanup) = tmpDir()
        defer { cleanup() }
        let url = hookURL(in: dir)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try #"{"version":1,"hooks":{}}"#.write(to: url, atomically: true, encoding: .utf8)

        #expect(throws: CopilotInstallerError.self) {
            try CopilotInstaller(projectRootURL: dir).install()
        }
        let error = CopilotInstallerError.unmanagedHookExists(url.path)
        #expect(error.localizedDescription.contains("unmanaged Copilot hook"))
        #expect(try String(contentsOf: url, encoding: .utf8) == #"{"version":1,"hooks":{}}"#)
    }

    @Test func reinstallReplacesManagedHookFile() throws {
        let (dir, cleanup) = tmpDir()
        defer { cleanup() }
        let url = hookURL(in: dir)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try #"{"alas_marker":"alas-managed-copilot-hook-v1","hooks":{"old":[]}}"#
            .write(to: url, atomically: true, encoding: .utf8)

        try CopilotInstaller(projectRootURL: dir).install()

        let installed = try installedJSON(in: dir)
        let hooks = installed["hooks"] as! [String: Any]
        #expect(hooks["old"] == nil)
        #expect(hooks["sessionStart"] != nil)
    }
}
