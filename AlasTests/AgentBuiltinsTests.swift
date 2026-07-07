import AppKit
import Testing
@testable import Alas

struct AgentBuiltinsTests {
    @Test func catalogHasExactlySevenEntriesInDeterministicOrder() {
        let ids = AgentBuiltins.catalog.map(\.id)
        #expect(ids == ["claude", "codex", "cursor-agent", "pi", "opencode", "gemini", "copilot"])
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

    @Test func copilotBuiltinMatchesRequiredDefinition() {
        let e = AgentBuiltins.entry(id: "copilot")
        #expect(e?.displayName == "Copilot")
        #expect(e?.binary == "copilot")
        #expect(e?.binaryOverride == nil)
        #expect(e?.promptModeArgs == ["-i"])
        #expect(e?.bypassPermissionsFlag == "--allow-tool=write")
        #expect(e?.isBuiltin == true)
        #expect(e?.isEnabled == true)
        #expect(e?.builtinLogoAssetName == "agent-copilot")
    }

    @Test func entryLookupReturnsNilForUnknownId() {
        #expect(AgentBuiltins.entry(id: "unknown-agent") == nil)
    }

    @Test func everyEntryHasNonEmptyPromptModeArgs() {
        for entry in AgentBuiltins.catalog {
            #expect(!entry.promptModeArgs.isEmpty, "\(entry.id) promptModeArgs missing")
        }
    }

    @Test func everyBuiltinHasLogoAssetThatResolves() {
        for entry in AgentBuiltins.catalog {
            guard let name = entry.builtinLogoAssetName else {
                #expect(Bool(false), "\(entry.id) missing builtinLogoAssetName")
                continue
            }
            // bundle is the test bundle; NSImage(named:) falls back to the
            // app-host main bundle, where the asset catalog is compiled.
            let bundle = Bundle(for: AlasMarkerForBundle.self)
            let image = bundle.image(forResource: name) ?? NSImage(named: name)
            #expect(image != nil, "\(entry.id) logo asset '\(name)' not found in main bundle")
        }
    }

    @Test func originalLogoPresentationUsesOriginalBuiltinAsset() throws {
        let claude = try #require(AgentBuiltins.entry(id: "claude"))
        let presentation = AgentLogoPresentation.resolve(for: claude)
        #expect(presentation == .asset(name: "agent-claude"))
    }

    @Test func logoPresentationKeepsCustomAgentsOnFallbackSymbol() {
        let custom = AgentDefinition(
            id: "custom",
            displayName: "Custom",
            binary: "custom-agent",
            binaryOverride: nil,
            promptModeArgs: ["run"],
            bypassPermissionsFlag: nil,
            extraTerminalArgs: nil,
            isBuiltin: false,
            isEnabled: true,
            builtinLogoAssetName: nil
        )
        let presentation = AgentLogoPresentation.resolve(for: custom)
        #expect(presentation == .fallbackSymbol)
    }

    @Test func codexLogoUsesCloudHexagonSvgWithoutAppIconBackground() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let svg = repoRoot.appendingPathComponent(
            "Alas/Resources/Assets.xcassets/AgentLogos/agent-codex.imageset/agent-codex.svg"
        )
        let source = try String(contentsOf: svg, encoding: .utf8)

        #expect(source.contains(#"id="codex-cloud-hexagon""#))
        #expect(!source.contains("<rect"))
    }
}

/// Marker used to locate the Alas test host bundle from inside Swift Testing.
private final class AlasMarkerForBundle {}
