import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACP new chat empty state")
struct ACPNewChatEmptyStateTests {
    @Test("fresh ready empty sessions show the new empty state")
    func freshReadyEmptySessionShowsEmptyState() {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "wt", title: "New session")
        session.setupState = .ready
        session.agentState = .ready

        #expect(ACPNewChatEmptyStatePolicy.isVisible(for: session))
    }

    @Test("restored sessions do not show the new empty state")
    func restoredSessionDoesNotShowEmptyState() {
        let session = ACPSession(
            id: "s",
            agentId: "codex",
            worktreeId: "wt",
            title: "Restored",
            hydrationState: .ready,
            restoredFromPersistence: true
        )
        session.setupState = .ready
        session.agentState = .ready

        #expect(!ACPNewChatEmptyStatePolicy.isVisible(for: session))
    }

    @Test("hydrating and failed sessions do not show the new empty state")
    func unavailableSessionStatesDoNotShowEmptyState() {
        let loading = ACPSession(
            id: "loading",
            agentId: "codex",
            worktreeId: "wt",
            title: "Loading",
            hydrationState: .loading
        )
        loading.setupState = .ready
        loading.agentState = .ready

        let failed = ACPSession(
            id: "failed",
            agentId: "codex",
            worktreeId: "wt",
            title: "Failed",
            hydrationState: .failed("boom")
        )
        failed.setupState = .ready
        failed.agentState = .ready

        #expect(!ACPNewChatEmptyStatePolicy.isVisible(for: loading))
        #expect(!ACPNewChatEmptyStatePolicy.isVisible(for: failed))
    }

    @Test("setup problems, agent failures, and existing transcript suppress the new empty state")
    func blockedOrNonEmptySessionsDoNotShowEmptyState() {
        let setup = ACPSession(id: "setup", agentId: "codex", worktreeId: "wt", title: "Setup")
        setup.setupState = .needsSetup(reason: "Install Codex")
        setup.agentState = .ready

        let errored = ACPSession(id: "errored", agentId: "codex", worktreeId: "wt", title: "Errored")
        errored.setupState = .ready
        errored.agentState = .failed("boom")

        let messaged = ACPSession(id: "messaged", agentId: "codex", worktreeId: "wt", title: "Messaged")
        messaged.setupState = .ready
        messaged.agentState = .ready
        messaged.transcript.messages.append(.systemNotice(id: UUID(), text: "notice"))

        #expect(!ACPNewChatEmptyStatePolicy.isVisible(for: setup))
        #expect(!ACPNewChatEmptyStatePolicy.isVisible(for: errored))
        #expect(!ACPNewChatEmptyStatePolicy.isVisible(for: messaged))
    }

    @Test("session errors suppress the new empty state")
    func sessionErrorsDoNotShowEmptyState() {
        let session = ACPSession(id: "errored", agentId: "codex", worktreeId: "wt", title: "Errored")
        session.setupState = .ready
        session.agentState = .ready
        session.lastError = "boom"

        #expect(!ACPNewChatEmptyStatePolicy.isVisible(for: session))
    }

    @Test("setup checking and unavailable agent states suppress the new empty state")
    func unavailableReadinessStatesDoNotShowEmptyState() {
        let checkingSetup = ACPSession(id: "checking", agentId: "codex", worktreeId: "wt", title: "Checking")
        checkingSetup.setupState = .checking
        checkingSetup.agentState = .ready

        let idleAgent = ACPSession(id: "idle", agentId: "codex", worktreeId: "wt", title: "Idle")
        idleAgent.setupState = .ready
        idleAgent.agentState = .idle

        let spawningAgent = ACPSession(id: "spawning", agentId: "codex", worktreeId: "wt", title: "Spawning")
        spawningAgent.setupState = .ready
        spawningAgent.agentState = .spawning

        let disconnectedAgent = ACPSession(
            id: "disconnected",
            agentId: "codex",
            worktreeId: "wt",
            title: "Disconnected"
        )
        disconnectedAgent.setupState = .ready
        disconnectedAgent.agentState = .disconnected

        #expect(!ACPNewChatEmptyStatePolicy.isVisible(for: checkingSetup))
        #expect(!ACPNewChatEmptyStatePolicy.isVisible(for: idleAgent))
        #expect(!ACPNewChatEmptyStatePolicy.isVisible(for: spawningAgent))
        #expect(!ACPNewChatEmptyStatePolicy.isVisible(for: disconnectedAgent))
    }

    @Test("fresh attached sessions remain empty even after receiving a remote session id")
    func remoteSessionIdDoesNotSuppressFreshEmptyState() {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "wt", title: "New session")
        session.setupState = .ready
        session.agentState = .ready
        session.remoteSessionId = "remote-id"

        #expect(ACPNewChatEmptyStatePolicy.isVisible(for: session))
    }

    @Test("starter prompt replaces an empty draft")
    func starterPromptReplacesEmptyDraft() {
        let draft = ACPStarterPrompt.reviewChanges.applying(to: .empty)

        #expect(draft == ACPComposerDraft(segments: [
            .text("Review the current changes in this worktree and suggest the next steps.")
        ]))
    }

    @Test("starter prompt appends after non-empty text with a blank line")
    func starterPromptAppendsAfterExistingText() {
        let existing = ACPComposerDraft(segments: [.text("Existing note")])
        let draft = ACPStarterPrompt.planFeature.applying(to: existing)

        #expect(draft == ACPComposerDraft(segments: [
            .text("Existing note\n\n"),
            .text("Help me plan this feature. Ask clarifying questions first if the goal is ambiguous.")
        ]))
    }

    @Test("starter prompts expose stable short labels")
    func starterPromptLabelsAreStable() {
        #expect(ACPStarterPrompt.allCases.map(\.label) == [
            "Review current changes",
            "Find a bug",
            "Plan a feature",
        ])
    }

    @Test("raised composer placement scales with available height")
    func raisedComposerPlacementScalesWithAvailableHeight() {
        let bottom = ACPComposerPlacement.bottomInset(for: .bottom, containerHeight: 800)
        let shortRaised = ACPComposerPlacement.bottomInset(for: .raisedEmpty, containerHeight: 360)
        let regularRaised = ACPComposerPlacement.bottomInset(for: .raisedEmpty, containerHeight: 720)
        let tallRaised = ACPComposerPlacement.bottomInset(for: .raisedEmpty, containerHeight: 1_200)

        #expect(bottom == 18)
        #expect(shortRaised > bottom)
        #expect(regularRaised > shortRaised)
        #expect(tallRaised == 320)
    }
}
