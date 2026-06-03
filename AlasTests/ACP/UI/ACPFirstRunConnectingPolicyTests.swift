import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACP first-run connecting policy")
struct ACPFirstRunConnectingPolicyTests {
    @Test("first-run connecting view copy stays stable")
    func firstRunConnectingViewCopyStaysStable() {
        #expect(ACPFirstRunConnectingViewCopy.title == "Connecting...")
        #expect(ACPFirstRunConnectingViewCopy.subtitle(agentDisplayName: "Codex") == "Preparing a new Codex chat.")
    }

    @Test("phase labels stay stable")
    func phaseLabelsStayStable() {
        #expect(ACPFirstRunConnectingPhase.allCases.map(\.label) == [
            "Checking setup",
            "Launching adapter",
            "Initializing",
            "Creating session",
        ])
    }

    @Test("fresh hydrating empty sessions show checking setup")
    func freshHydratingEmptySessionShowsCheckingSetup() {
        let session = ACPSession(
            id: "s",
            agentId: "codex",
            worktreeId: "wt",
            title: "New session",
            hydrationState: .loading
        )

        #expect(ACPFirstRunConnectingPolicy.phase(for: session) == .checkingSetup)
        #expect(ACPFirstRunConnectingPolicy.isVisible(for: session))
    }

    @Test("fresh checking setup sessions show checking setup")
    func freshCheckingSetupSessionShowsCheckingSetup() {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "wt", title: "New session")
        session.setupState = .checking
        session.agentState = .idle

        #expect(ACPFirstRunConnectingPolicy.phase(for: session) == .checkingSetup)
    }

    @Test("fresh spawning sessions show launching adapter")
    func freshSpawningSessionShowsLaunchingAdapter() {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "wt", title: "New session")
        session.setupState = .ready
        session.agentState = .spawning

        #expect(ACPFirstRunConnectingPolicy.phase(for: session) == .launchingAdapter)
    }

    @Test("runtime phase wins while remote id is assigned before ready")
    func runtimePhaseWinsAfterRemoteIdArrivesBeforeReady() {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "wt", title: "New session")
        session.setupState = .ready
        session.agentState = .spawning
        session.remoteSessionId = "remote-new"
        session.firstRunConnectingPhase = .creatingSession

        #expect(ACPFirstRunConnectingPolicy.phase(for: session) == .creatingSession)
    }

    @Test("fresh ready empty sessions use the normal empty state")
    func freshReadyEmptySessionDoesNotShowFirstRunConnecting() {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "wt", title: "New session")
        session.setupState = .ready
        session.agentState = .ready

        #expect(ACPFirstRunConnectingPolicy.phase(for: session) == nil)
        #expect(!ACPFirstRunConnectingPolicy.isVisible(for: session))
        #expect(ACPNewChatEmptyStatePolicy.isVisible(for: session))
    }

    @Test("restored nonempty and failed sessions do not show first-run connecting")
    func blockedSessionsDoNotShowFirstRunConnecting() {
        let restored = ACPSession(
            id: "restored",
            agentId: "codex",
            worktreeId: "wt",
            title: "Restored",
            hydrationState: .loading,
            restoredFromPersistence: true
        )

        let messaged = ACPSession(id: "messaged", agentId: "codex", worktreeId: "wt", title: "Messaged")
        messaged.transcript.messages.append(.systemNotice(id: UUID(), text: "notice"))

        let setup = ACPSession(id: "setup", agentId: "codex", worktreeId: "wt", title: "Setup")
        setup.setupState = .needsSetup(reason: "Install Codex")

        let auth = ACPSession(id: "auth", agentId: "codex", worktreeId: "wt", title: "Auth")
        auth.setupState = .needsAuth(methods: [], reason: "Sign in")

        let failedHydration = ACPSession(
            id: "failed-hydration",
            agentId: "codex",
            worktreeId: "wt",
            title: "Failed hydration",
            hydrationState: .failed("boom")
        )

        let errored = ACPSession(id: "errored", agentId: "codex", worktreeId: "wt", title: "Errored")
        errored.lastError = "boom"

        let disconnected = ACPSession(id: "disconnected", agentId: "codex", worktreeId: "wt", title: "Disconnected")
        disconnected.setupState = .ready
        disconnected.agentState = .disconnected

        let failedAgent = ACPSession(id: "failed-agent", agentId: "codex", worktreeId: "wt", title: "Failed agent")
        failedAgent.setupState = .ready
        failedAgent.agentState = .failed("boom")

        for session in [restored, messaged, setup, auth, failedHydration, errored, disconnected, failedAgent] {
            #expect(ACPFirstRunConnectingPolicy.phase(for: session) == nil)
            #expect(!ACPFirstRunConnectingPolicy.isVisible(for: session))
        }
    }

    @Test("prior remote attach without runtime phase does not show first-run connecting")
    func priorRemoteAttachDoesNotShowFirstRunConnecting() {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "wt", title: "Existing remote")
        session.setupState = .ready
        session.agentState = .spawning
        session.remoteSessionId = "remote-old"

        #expect(ACPFirstRunConnectingPolicy.phase(for: session) == nil)
    }

    @Test("composer placement is raised during first-run connecting or new empty state")
    func composerPlacementPolicyRaisesFirstRunConnecting() {
        #expect(ACPFirstRunConnectingPolicy.composerPlacement(
            firstRunConnecting: true,
            newEmptySession: false
        ) == .raisedEmpty)
        #expect(ACPFirstRunConnectingPolicy.composerPlacement(
            firstRunConnecting: false,
            newEmptySession: true
        ) == .raisedEmpty)
        #expect(ACPFirstRunConnectingPolicy.composerPlacement(
            firstRunConnecting: false,
            newEmptySession: false
        ) == .bottom)
    }
}
