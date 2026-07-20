import Foundation
import Testing
@testable import Alas

struct GGConfigReaderTests {
    private func makeRepo(configJSON: String?) throws -> String {
        let dir = NSTemporaryDirectory() + "gg-cfg-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir + "/.git/gg", withIntermediateDirectories: true)
        if let configJSON {
            try configJSON.write(toFile: dir + "/.git/gg/config.json", atomically: true, encoding: .utf8)
        }
        return dir
    }

    private func makeGlobal(configJSON: String) throws -> String {
        let path = NSTemporaryDirectory() + "gg-global-" + UUID().uuidString + ".json"
        try configJSON.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @Test func readsRepoUsername() throws {
        let repo = try makeRepo(configJSON: #"{"defaults":{"branch_username":"nacho"}}"#)
        #expect(GGConfigReader.branchUsername(repoPath: repo, globalConfigPath: nil) == "nacho")
    }

    @Test func fallsBackToGlobalWhenRepoLacksIt() throws {
        let repo = try makeRepo(configJSON: #"{"defaults":{}}"#)
        let global = try makeGlobal(configJSON: #"{"defaults":{"branch_username":"globaluser"}}"#)
        #expect(GGConfigReader.branchUsername(repoPath: repo, globalConfigPath: global) == "globaluser")
    }

    @Test func nilWhenNeitherSetsItOrGarbage() throws {
        let noKey = try makeRepo(configJSON: #"{"defaults":{}}"#)
        #expect(GGConfigReader.branchUsername(repoPath: noKey, globalConfigPath: nil) == nil)
        let garbage = try makeRepo(configJSON: "not json")
        #expect(GGConfigReader.branchUsername(repoPath: garbage, globalConfigPath: nil) == nil)
        let missing = try makeRepo(configJSON: nil)
        #expect(GGConfigReader.branchUsername(repoPath: missing, globalConfigPath: nil) == nil)
    }

    @Test func composesStackBranch() {
        #expect(GGConfigReader.composeStackBranch(username: "nacho", stackName: "auth-flow") == "nacho/auth-flow")
    }
}
