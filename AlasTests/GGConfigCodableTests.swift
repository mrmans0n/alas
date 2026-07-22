import Foundation
import Testing
@testable import Alas

struct GGConfigCodableTests {
    @Test func projectConfigGGModeDefaultsToAutoWhenMissing() throws {
        let json = """
        {"id": "p1", "name": "alas", "path": "/tmp/alas", "color": "teal",
         "addedAt": 700000000}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let project = try decoder.decode(ProjectConfig.self, from: Data(json.utf8))
        #expect(project.ggMode == .auto)
    }

    @Test func projectConfigGGModeRoundTrips() throws {
        var project = ProjectConfig(
            id: "p1", name: "alas", path: "/tmp/alas", color: "teal", addedAt: Date()
        )
        project.ggMode = .on
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(ProjectConfig.self, from: data)
        #expect(decoded.ggMode == .on)
    }

    @Test func projectConfigGGWorktreeModesDefaultEmptyWhenMissing() throws {
        let json = """
        {"id": "p1", "name": "alas", "path": "/tmp/alas", "color": "teal",
         "addedAt": 700000000}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let project = try decoder.decode(ProjectConfig.self, from: Data(json.utf8))

        #expect(project.ggWorktreeModes.isEmpty)
    }

    @Test func projectConfigGGWorktreeModesEncodeSparselyAndRoundTrip() throws {
        var project = ProjectConfig(
            id: "p1", name: "alas", path: "/tmp/alas", color: "teal", addedAt: Date(),
            ggWorktreeModes: ["on-worktree": .on, "off-worktree": .off, "inherited-worktree": .inherit]
        )
        let data = try JSONEncoder().encode(project)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let modes = try #require(object["ggWorktreeModes"] as? [String: String])

        #expect(modes == ["on-worktree": "on", "off-worktree": "off"])

        project.ggWorktreeModes = [:]
        let emptyData = try JSONEncoder().encode(project)
        let emptyObject = try #require(JSONSerialization.jsonObject(with: emptyData) as? [String: Any])
        #expect(emptyObject["ggWorktreeModes"] == nil)

        let decoded = try JSONDecoder().decode(ProjectConfig.self, from: data)
        #expect(decoded.ggWorktreeModes == ["on-worktree": .on, "off-worktree": .off])
    }

    @Test func stackedDiffsEnabledDefaultsTrueOnLegacyConfig() throws {
        // Simulate a config written before `stackedDiffsEnabled` existed by
        // encoding the defaults and stripping the key from the changes
        // section before decoding. `AppConfig.init(from:)` requires other
        // top-level keys, so a bare minimal JSON literal isn't decodable.
        let defaultsData = try JSONEncoder().encode(AppConfig.defaults)
        var root = try JSONSerialization.jsonObject(with: defaultsData) as! [String: Any]
        var changesSection = root["changes"] as! [String: Any]
        changesSection.removeValue(forKey: "stackedDiffsEnabled")
        root["changes"] = changesSection
        let legacyData = try JSONSerialization.data(withJSONObject: root)

        let config = try JSONDecoder().decode(AppConfig.self, from: legacyData)
        #expect(config.changes.stackedDiffsEnabled)
    }

    @Test func stackedDiffsEnabledRoundTrips() throws {
        var config = AppConfig.defaults
        config.changes.stackedDiffsEnabled = false
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(!decoded.changes.stackedDiffsEnabled)
    }
}
