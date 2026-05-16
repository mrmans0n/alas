import Testing
import Foundation
@testable import Alas

struct ProjectConfigAgentOverrideTests {
    @Test func defaultsUseGlobalAndNoAgent() {
        let s = ProjectStartupScripts.defaults
        #expect(s.worktreeAgentMode == .useGlobal)
        #expect(s.worktreeAgentId == nil)
        #expect(s.worktreeAgentUseBypassPermissions == false)
    }

    @Test func decodesLegacyProjectStartupScriptsWithoutAgentFields() throws {
        let json = """
        {
          "sessionOpenMode": "useGlobal",
          "sessionOpenScript": "",
          "worktreeCreateMode": "useGlobal",
          "worktreeCreateScript": ""
        }
        """
        let s = try JSONDecoder().decode(ProjectStartupScripts.self, from: Data(json.utf8))
        #expect(s.worktreeAgentMode == .useGlobal)
        #expect(s.worktreeAgentId == nil)
        #expect(s.worktreeAgentUseBypassPermissions == false)
    }

    @Test func roundTripsOverrideFields() throws {
        var s = ProjectStartupScripts.defaults
        s.worktreeAgentMode = .overrideGlobal
        s.worktreeAgentId = "claude"
        s.worktreeAgentUseBypassPermissions = true
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(ProjectStartupScripts.self, from: data)
        #expect(decoded.worktreeAgentMode == .overrideGlobal)
        #expect(decoded.worktreeAgentId == "claude")
        #expect(decoded.worktreeAgentUseBypassPermissions == true)
        // Full-struct equality catches any future field that isn't part
        // of Codable conformance.
        #expect(decoded == s)
    }

    @Test func decodesPartialAgentOverrideFields() throws {
        // Each new field uses `try?` independently; a JSON with some
        // present and some absent must decode the present ones and
        // default the rest, not throw.
        let json = """
        {
          "sessionOpenMode": "useGlobal",
          "sessionOpenScript": "",
          "worktreeCreateMode": "useGlobal",
          "worktreeCreateScript": "",
          "worktreeAgentMode": "overrideGlobal"
        }
        """
        let s = try JSONDecoder().decode(ProjectStartupScripts.self, from: Data(json.utf8))
        #expect(s.worktreeAgentMode == .overrideGlobal)
        #expect(s.worktreeAgentId == nil)
        #expect(s.worktreeAgentUseBypassPermissions == false)
    }
}
