// AlasTests/AgentAutoLaunchTests.swift
import Testing
import Foundation
@testable import Alas

struct AgentAutoLaunchTests {
    // Use non-builtin IDs so the test registry doesn't collide with the
    // AgentBuiltins.catalog entries that AgentRegistry always prepends.
    private func mkAgent(id: String, binary: String, bypass: String?) -> AgentDefinition {
        AgentDefinition(
            id: id, displayName: id, binary: binary,
            binaryOverride: nil, promptModeArgs: [],
            bypassPermissionsFlag: bypass,
            isBuiltin: false, isEnabled: true, builtinLogoAssetName: nil
        )
    }

    private func registry(_ agents: [AgentDefinition], installed: [String]) -> AgentRegistry {
        AgentRegistry(builtinState: [:], customs: agents, installedIds: Set(installed))
    }

    @Test func resolvedNoneWhenGlobalAgentIdNil() {
        let r = registry([], installed: [])
        let resolved = AgentAutoLaunch.resolve(
            registry: r,
            globalAgentId: nil,
            globalUseBypass: false,
            projectMode: .useGlobal,
            projectAgentId: nil,
            projectUseBypass: false
        )
        #expect(resolved == nil)
    }

    @Test func resolvedGlobalWhenProjectUsesGlobal() {
        let agent = mkAgent(id: "test-claude", binary: "claude", bypass: "--dangerously-skip-permissions")
        let r = registry([agent], installed: ["test-claude"])
        let resolved = AgentAutoLaunch.resolve(
            registry: r,
            globalAgentId: "test-claude",
            globalUseBypass: true,
            projectMode: .useGlobal,
            projectAgentId: nil,
            projectUseBypass: false
        )!
        #expect(resolved.argv == ["claude", "--dangerously-skip-permissions"])
    }

    @Test func resolvedProjectOverridesGlobal() {
        let agentA = mkAgent(id: "test-claude", binary: "claude", bypass: "--yolo")
        let agentB = mkAgent(id: "test-codex", binary: "codex", bypass: nil)
        let r = registry([agentA, agentB], installed: ["test-claude", "test-codex"])
        let resolved = AgentAutoLaunch.resolve(
            registry: r,
            globalAgentId: "test-claude",
            globalUseBypass: true,
            projectMode: .overrideGlobal,
            projectAgentId: "test-codex",
            projectUseBypass: true
        )!
        // test-codex has no bypass flag; the bypass toggle is a no-op for it.
        #expect(resolved.argv == ["codex"])
    }

    @Test func resolvedDisabledMeansNone() {
        let agent = mkAgent(id: "test-claude", binary: "claude", bypass: nil)
        let r = registry([agent], installed: ["test-claude"])
        let resolved = AgentAutoLaunch.resolve(
            registry: r,
            globalAgentId: "test-claude",
            globalUseBypass: false,
            projectMode: .disabled,
            projectAgentId: nil,
            projectUseBypass: false
        )
        #expect(resolved == nil)
    }

    @Test func resolvedNoneWhenAgentNotEnabledOrInstalled() {
        let agent = mkAgent(id: "test-claude", binary: "claude", bypass: nil)
        let r = registry([agent], installed: [])  // not installed
        let resolved = AgentAutoLaunch.resolve(
            registry: r,
            globalAgentId: "test-claude",
            globalUseBypass: false,
            projectMode: .useGlobal,
            projectAgentId: nil,
            projectUseBypass: false
        )
        #expect(resolved == nil)
    }

    @Test func appendToGlobalTreatedAsOverride() {
        // appendToGlobal is a startup-script semantic. For the agent override
        // it just means "use project agent if set, else global".
        let agentA = mkAgent(id: "test-claude", binary: "claude", bypass: nil)
        let agentB = mkAgent(id: "test-codex", binary: "codex", bypass: nil)
        let r = registry([agentA, agentB], installed: ["test-claude", "test-codex"])
        let resolved = AgentAutoLaunch.resolve(
            registry: r,
            globalAgentId: "test-claude",
            globalUseBypass: false,
            projectMode: .appendToGlobal,
            projectAgentId: "test-codex",
            projectUseBypass: false
        )!
        #expect(resolved.argv == ["codex"])
    }

    @Test func resolveExplicitReturnsNilForUnknownAgent() {
        let r = registry([], installed: [])
        let resolved = AgentAutoLaunch.resolveExplicit(
            agentId: "missing",
            registry: r,
            useBypass: true
        )
        #expect(resolved == nil)
    }

    @Test func resolveExplicitAppendsBypassFlagWhenSupported() {
        let agent = mkAgent(id: "test-claude", binary: "claude", bypass: "--dangerously-skip-permissions")
        let r = registry([agent], installed: ["test-claude"])
        let resolved = AgentAutoLaunch.resolveExplicit(
            agentId: "test-claude",
            registry: r,
            useBypass: true
        )!
        #expect(resolved.argv == ["claude", "--dangerously-skip-permissions"])
    }

    @Test func resolveExplicitOmitsBypassFlagWhenNotSupported() {
        let agent = mkAgent(id: "test-pi", binary: "pi", bypass: nil)
        let r = registry([agent], installed: ["test-pi"])
        let resolved = AgentAutoLaunch.resolveExplicit(
            agentId: "test-pi",
            registry: r,
            useBypass: true
        )!
        #expect(resolved.argv == ["pi"])
    }

    @Test func resolvedGlobalReturnsNilWhenNoAgentIdButBypassEnabled() {
        // Bypass permissions is stored independently of the default agent.
        // When no default agent is set, auto-launch should return nil
        // regardless of the bypass toggle.
        let r = registry([], installed: [])
        let resolved = AgentAutoLaunch.resolve(
            registry: r,
            globalAgentId: nil,
            globalUseBypass: true,
            projectMode: .useGlobal,
            projectAgentId: nil,
            projectUseBypass: false
        )
        #expect(resolved == nil)
    }

    @Test func resolveExplicitOmitsBypassWhenUseBypassIsFalse() {
        let agent = mkAgent(id: "test-claude", binary: "claude", bypass: "--dangerously-skip-permissions")
        let r = registry([agent], installed: ["test-claude"])
        let resolved = AgentAutoLaunch.resolveExplicit(
            agentId: "test-claude",
            registry: r,
            useBypass: false
        )!
        #expect(resolved.argv == ["claude"])
    }

    @Test func explicitSelectionUsesBypassWithoutDefaultAgent() {
        let agent = mkAgent(id: "test-claude", binary: "claude", bypass: "--dangerously-skip-permissions")
        let r = registry([agent], installed: ["test-claude"])
        let defaultResolved = AgentAutoLaunch.resolve(
            registry: r,
            globalAgentId: nil,
            globalUseBypass: true,
            projectMode: .useGlobal,
            projectAgentId: nil,
            projectUseBypass: false
        )
        let explicitResolved = AgentAutoLaunch.resolveExplicit(
            agentId: "test-claude",
            registry: r,
            useBypass: true
        )

        #expect(defaultResolved == nil)
        #expect(explicitResolved?.argv == ["claude", "--dangerously-skip-permissions"])
    }
}
