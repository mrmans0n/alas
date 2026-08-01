import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACP worktree session bootstrapper")
struct ACPWorktreeSessionBootstrapperTests {
    private static let promptID = UUID(uuidString: "4C71A32A-D3D7-462F-843B-E543D4C7FB87")!
    private static let request = ACPWorktreeSessionRequest(
        worktreeId: "worktree",
        sessionID: "mission-session",
        agentId: "codex",
        promptID: promptID,
        prompt: "Investigate."
    )

    @Test("restart reuses the persisted session and does not duplicate its prompt")
    func restartReusesSessionAndDoesNotDuplicatePrompt() async throws {
        let fake = BootstrapFake(sessionExists: true, queuedPromptIDs: [Self.promptID])
        let bootstrapper = ACPWorktreeSessionBootstrapper(environment: fake.environment)

        let id = try await bootstrapper.start(Self.request)

        #expect(id == Self.request.sessionID)
        #expect(fake.createCalls == 0)
        #expect(fake.enqueueCalls == 1)
        #expect(fake.promptIDs == [Self.promptID])
        #expect(fake.attachCalls == 1)
    }

    @Test("missing manager fails before session setup")
    func missingManagerFailsBeforeSessionSetup() async {
        let fake = BootstrapFake(
            sessionExists: false,
            prepareError: BootstrapFakeError.missingManager
        )
        let bootstrapper = ACPWorktreeSessionBootstrapper(environment: fake.environment)

        await #expect(throws: ACPWorktreeSessionBootstrapError.self) {
            try await bootstrapper.start(Self.request)
        }

        #expect(fake.prepareCalls == 1)
        #expect(fake.enqueueCalls == 0)
        #expect(fake.attachCalls == 0)
    }

    @Test("queue persistence failure does not attach")
    func queuePersistenceFailureDoesNotAttach() async {
        let fake = BootstrapFake(sessionExists: false, enqueueSucceeds: false)
        let bootstrapper = ACPWorktreeSessionBootstrapper(environment: fake.environment)

        await #expect(throws: ACPWorktreeSessionBootstrapError.self) {
            try await bootstrapper.start(Self.request)
        }

        #expect(fake.createCalls == 1)
        #expect(fake.attachCalls == 0)
    }

    @Test("setup and authentication failures use their ready-state reasons")
    func setupAndAuthenticationFailuresUseTheirReadyStateReasons() async {
        for (state, expectedMessage) in [
            (ACPBootstrapReadyState.needsSetup("Install Codex."), "Install Codex."),
            (.needsAuthentication("Sign in to Codex."), "Sign in to Codex."),
        ] {
            let fake = BootstrapFake(sessionExists: false, readyState: state)
            let bootstrapper = ACPWorktreeSessionBootstrapper(environment: fake.environment)

            do {
                try await bootstrapper.start(Self.request)
                Issue.record("Expected ACP bootstrap to fail")
            } catch let error as ACPWorktreeSessionBootstrapError {
                #expect(error.message == expectedMessage)
            } catch {
                Issue.record("Expected ACPWorktreeSessionBootstrapError, got \(error)")
            }

            #expect(fake.attachCalls == 1)
        }
    }

    @Test("successful attach returns the requested stable session ID")
    func successfulAttachReturnsRequestedStableSessionID() async throws {
        let fake = BootstrapFake(sessionExists: false)
        let bootstrapper = ACPWorktreeSessionBootstrapper(environment: fake.environment)

        #expect(try await bootstrapper.start(Self.request) == Self.request.sessionID)
        #expect(fake.createCalls == 1)
        #expect(fake.promptIDs == [Self.promptID])
        #expect(fake.attachCalls == 1)
    }
}

@MainActor
private final class BootstrapFake {
    var sessionExists: Bool
    var promptIDs: [UUID]
    var enqueueSucceeds: Bool
    var state: ACPBootstrapReadyState
    var prepareError: Error?
    private(set) var prepareCalls = 0
    private(set) var createCalls = 0
    private(set) var enqueueCalls = 0
    private(set) var attachCalls = 0

    init(
        sessionExists: Bool,
        queuedPromptIDs: [UUID] = [],
        enqueueSucceeds: Bool = true,
        readyState: ACPBootstrapReadyState = .ready,
        prepareError: Error? = nil
    ) {
        self.sessionExists = sessionExists
        promptIDs = queuedPromptIDs
        self.enqueueSucceeds = enqueueSucceeds
        state = readyState
        self.prepareError = prepareError
    }

    var environment: ACPWorktreeSessionBootstrapper.Environment {
        .init(
            sessionExists: { [weak self] _, _ in self?.sessionExists ?? false },
            prepareSession: { [weak self] _, _, _ in
                guard let self else { return }
                self.prepareCalls += 1
                if let prepareError = self.prepareError { throw prepareError }
                if !self.sessionExists {
                    self.createCalls += 1
                    self.sessionExists = true
                }
            },
            enqueuePrompt: { [weak self] _, _, id, _ in
                guard let self else { return false }
                self.enqueueCalls += 1
                guard self.enqueueSucceeds else { return false }
                if !self.promptIDs.contains(id) {
                    self.promptIDs.append(id)
                }
                return true
            },
            attach: { [weak self] _, _, _ in self?.attachCalls += 1 },
            readyState: { [weak self] _, _ in self?.state ?? .failed("ACP session is unavailable.") }
        )
    }
}

private enum BootstrapFakeError: Error {
    case missingManager
}
