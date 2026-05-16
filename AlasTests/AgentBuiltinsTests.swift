import Testing
import Foundation
@testable import Alas

struct AgentBuiltinsTests {
    @Test func catalogHasExactlySixEntriesInDeterministicOrder() {
        let ids = AgentBuiltins.catalog.map(\.id)
        #expect(ids == ["claude", "codex", "cursor-agent", "pi", "opencode", "gemini"])
    }

    @Test func everyEntryIsMarkedBuiltin() {
        for entry in AgentBuiltins.catalog {
            #expect(entry.isBuiltin, "\(entry.id) must be flagged isBuiltin")
        }
    }

    @Test func everyEntryHasNonEmptyBinaryAndDisplayName() {
        for entry in AgentBuiltins.catalog {
            #expect(!entry.binary.isEmpty, "\(entry.id) binary missing")
            #expect(!entry.displayName.isEmpty, "\(entry.id) displayName missing")
        }
    }

    @Test func defaultEnabledIsTrueForAllBuiltins() {
        for entry in AgentBuiltins.catalog {
            #expect(entry.isEnabled, "\(entry.id) should default to enabled")
        }
    }

    @Test func builtinIdsMatchOldCommitAIToolRawValues() {
        // The migration plan keeps `changes.aiToolId` strings stable.
        // These IDs must be byte-for-byte identical to the old CommitAITool.rawValues:
        let preservedIds = ["claude", "codex", "cursor-agent", "pi"]
        let catalogIds = Set(AgentBuiltins.catalog.map(\.id))
        for id in preservedIds {
            #expect(catalogIds.contains(id), "\(id) must remain a built-in id")
        }
    }
}
