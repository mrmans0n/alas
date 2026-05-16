import Testing
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

    @Test func entryLookupReturnsCorrectEntryForKnownId() {
        let e = AgentBuiltins.entry(id: "gemini")
        #expect(e?.displayName == "Gemini CLI")
    }

    @Test func entryLookupReturnsNilForUnknownId() {
        #expect(AgentBuiltins.entry(id: "unknown-agent") == nil)
    }

    @Test func everyEntryHasNonEmptyPromptModeArgs() {
        for entry in AgentBuiltins.catalog {
            #expect(!entry.promptModeArgs.isEmpty, "\(entry.id) promptModeArgs missing")
        }
    }

    @Test func everyBuiltinHasLogoAssetName() {
        for entry in AgentBuiltins.catalog {
            #expect(entry.builtinLogoAssetName != nil, "\(entry.id) missing builtinLogoAssetName")
        }
    }
}
