import Foundation
import Testing
@testable import Alas

struct GGStackGateTests {
    private func makeRepo(withGGConfig: Bool) throws -> String {
        let dir = NSTemporaryDirectory() + "gg-gate-" + UUID().uuidString
        let ggDir = dir + "/.git/gg"
        try FileManager.default.createDirectory(
            atPath: withGGConfig ? ggDir : dir + "/.git",
            withIntermediateDirectories: true
        )
        if withGGConfig {
            FileManager.default.createFile(atPath: ggDir + "/config.json", contents: Data("{}".utf8))
        }
        return dir
    }

    private func commit(body: String) -> CommitInfo {
        CommitInfo(
            sha: String(repeating: "a", count: 40), shortSha: "aaaaaaa",
            author: "Test", authorInitials: "T", date: Date(),
            subject: "subject", body: body, conventionalTag: nil,
            filesChanged: 1, insertions: 1, deletions: 0
        )
    }

    @Test func detectsGGConfigFile() throws {
        #expect(GGStackGate.repoHasGGConfig(repoPath: try makeRepo(withGGConfig: true)))
        #expect(!GGStackGate.repoHasGGConfig(repoPath: try makeRepo(withGGConfig: false)))
    }

    @Test func projectEnabledMatrix() throws {
        let ggRepo = try makeRepo(withGGConfig: true)
        let plainRepo = try makeRepo(withGGConfig: false)
        // Master off / gg missing kill everything.
        #expect(!GGStackGate.projectEnabled(masterEnabled: false, ggInstalled: true, mode: .on, repoPath: ggRepo))
        #expect(!GGStackGate.projectEnabled(masterEnabled: true, ggInstalled: false, mode: .on, repoPath: ggRepo))
        // off always hides; on always allows; auto follows the config file.
        #expect(!GGStackGate.projectEnabled(masterEnabled: true, ggInstalled: true, mode: .off, repoPath: ggRepo))
        #expect(GGStackGate.projectEnabled(masterEnabled: true, ggInstalled: true, mode: .on, repoPath: plainRepo))
        #expect(GGStackGate.projectEnabled(masterEnabled: true, ggInstalled: true, mode: .auto, repoPath: ggRepo))
        #expect(!GGStackGate.projectEnabled(masterEnabled: true, ggInstalled: true, mode: .auto, repoPath: plainRepo))
    }

    @Test func stackShapeRequiresGGIDTrailer() {
        let stacked = commit(body: "Some detail.\n\nGG-ID: abc123\nGG-Parent: def456")
        let plain = commit(body: "Just a normal body mentioning GG-ID: in prose? No — mid-line doesn't count.")
        #expect(GGStackGate.isStackShaped(commits: [plain, stacked]))
        #expect(!GGStackGate.isStackShaped(commits: [plain]))
        #expect(!GGStackGate.isStackShaped(commits: []))
    }
}
