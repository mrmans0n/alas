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

    @Test func readsRepoBase() throws {
        let repo = try makeRepo(configJSON: #"{"defaults":{"base":"release/1.2"}}"#)
        #expect(GGConfigReader.defaultBase(repoPath: repo, globalConfigPath: nil) == "release/1.2")
    }

    @Test func baseFallsBackToGlobal() throws {
        let repo = try makeRepo(configJSON: #"{"defaults":{}}"#)
        let global = try makeGlobal(configJSON: #"{"defaults":{"base":"develop"}}"#)
        #expect(GGConfigReader.defaultBase(repoPath: repo, globalConfigPath: global) == "develop")
    }

    @Test func baseNilWhenAbsentOrGarbage() throws {
        let noKey = try makeRepo(configJSON: #"{"defaults":{}}"#)
        #expect(GGConfigReader.defaultBase(repoPath: noKey, globalConfigPath: nil) == nil)
        let garbage = try makeRepo(configJSON: "not json")
        #expect(GGConfigReader.defaultBase(repoPath: garbage, globalConfigPath: nil) == nil)
    }

    @Test func effectiveConfigUsesTypedDefaultsWhenValuesAreAbsent() throws {
        let repo = try makeRepo(configJSON: #"{"defaults":{}}"#)

        #expect(
            GGConfigReader.effectiveConfig(repoPath: repo, globalConfigPath: nil)
                == .defaults
        )
    }

    @Test func effectiveConfigReadsGlobalValues() throws {
        let repo = try makeRepo(configJSON: nil)
        let global = try makeGlobal(
            configJSON: #"{"defaults":{"sync_auto_rebase":true,"sync_auto_lint":true,"sync_behind_threshold":4}}"#
        )

        let config = GGConfigReader.effectiveConfig(repoPath: repo, globalConfigPath: global)
        #expect(config.syncAutoRebase)
        #expect(config.syncBehindThreshold == 4)
        #expect(config.syncAutoLint)
    }

    @Test func effectiveConfigLocalDefaultsReplaceGlobalDefaults() throws {
        let repo = try makeRepo(configJSON: #"{"defaults":{"sync_auto_rebase":true}}"#)
        let global = try makeGlobal(
            configJSON: #"{"defaults":{"sync_auto_rebase":false,"sync_behind_threshold":4}}"#
        )

        #expect(
            GGConfigReader.effectiveConfig(repoPath: repo, globalConfigPath: global)
                == GGEffectiveConfig(syncAutoRebase: true, syncBehindThreshold: 1)
        )
    }

    @Test func effectiveConfigMalformedLocalKeyUsesHardcodedDefault() throws {
        let repo = try makeRepo(
            configJSON: #"{"defaults":{"sync_auto_rebase":"yes","sync_behind_threshold":2}}"#
        )
        let global = try makeGlobal(
            configJSON: #"{"defaults":{"sync_auto_rebase":true,"sync_behind_threshold":"four"}}"#
        )

        #expect(
            GGConfigReader.effectiveConfig(repoPath: repo, globalConfigPath: global)
                == GGEffectiveConfig(syncAutoRebase: false, syncBehindThreshold: 2)
        )
    }

    @Test func effectiveConfigRejectsCrossTypeLocalValues() throws {
        let repo = try makeRepo(
            configJSON: #"{"defaults":{"sync_auto_rebase":1,"sync_behind_threshold":true}}"#
        )
        let global = try makeGlobal(
            configJSON: #"{"defaults":{"sync_auto_rebase":false,"sync_behind_threshold":4}}"#
        )

        #expect(
            GGConfigReader.effectiveConfig(repoPath: repo, globalConfigPath: global)
                == GGEffectiveConfig(syncAutoRebase: false, syncBehindThreshold: 1)
        )
    }

    @Test func effectiveConfigFallsBackForNegativeBehindThreshold() throws {
        let repo = try makeRepo(
            configJSON: #"{"defaults":{"sync_auto_rebase":true,"sync_behind_threshold":-1}}"#
        )

        #expect(
            GGConfigReader.effectiveConfig(repoPath: repo, globalConfigPath: nil)
                == GGEffectiveConfig(syncAutoRebase: true, syncBehindThreshold: 1)
        )
    }

    @Test func effectiveConfigInvalidLocalFileDoesNotExposeGlobalPolicy() throws {
        let repo = try makeRepo(configJSON: "not json")
        let global = try makeGlobal(
            configJSON: #"{"defaults":{"sync_auto_rebase":true,"sync_behind_threshold":4}}"#
        )

        #expect(GGConfigReader.effectiveConfig(repoPath: repo, globalConfigPath: global) == .defaults)
    }
}
