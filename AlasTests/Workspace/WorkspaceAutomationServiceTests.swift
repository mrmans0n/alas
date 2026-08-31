import Foundation
import Testing
@testable import Alas

@Suite("Workspace automation service")
struct WorkspaceAutomationServiceTests {
    @Test func listAndShowExposeVersionedNonMutatingCheckoutState() async throws {
        let checkoutID = UUID()
        let workspaceID = UUID()
        let memberID = UUID()
        let store = try await makeStore(state: .init(checkouts: [
            checkout(
                id: checkoutID,
                workspaceID: workspaceID,
                members: [
                    member(id: memberID, projectID: "project-a", availability: .available),
                    member(projectID: "project-b", availability: .identityConflict),
                ]
            ),
            checkout(id: UUID(), archivedAt: Date(), members: [member(projectID: "archived", availability: .available)]),
        ]))
        let service = WorkspaceAutomationService(store: store, isEnabled: { true })

        let list = try await service.listCheckouts()
        let shown = try await service.showCheckout(id: checkoutID)

        #expect(list.version == 1)
        #expect(list.checkouts.map(\.id) == [checkoutID])
        #expect(list.checkouts.first?.health == .needsAttention)
        #expect(shown.checkout.id == checkoutID)
        #expect(shown.checkout.workspaceID == workspaceID)
        #expect(shown.checkout.members.map(\.id).contains(memberID))
        #expect(try await loaded(store).checkouts.count == 2)
    }

    @Test func focusRequiresExplicitAvailableMemberAndNeverUsesRepositoryFocusImplicitly() async throws {
        let checkoutID = UUID()
        let available = UUID()
        let unavailable = UUID()
        let store = try await makeStore(state: .init(checkouts: [
            checkout(id: checkoutID, members: [
                member(id: available, projectID: "project-a", availability: .available),
                member(id: unavailable, projectID: "project-b", availability: .missing),
            ]),
        ]))
        var selectedCheckout: UUID?
        var focusedMember: (checkout: UUID, member: UUID)?
        let service = WorkspaceAutomationService(
            store: store,
            isEnabled: { true },
            selectCheckout: { selectedCheckout = $0 },
            focusMember: { focusedMember = ($0, $1) },
            observer: AutomationObserver(results: [
                available: .exactLineage("available-lineage"),
                unavailable: .missing,
            ])
        )

        let target = try await service.memberTarget(checkoutID: checkoutID, memberID: available)
        try await service.selectCheckout(id: checkoutID)
        try await service.focusMember(checkoutID: checkoutID, memberID: available)

        #expect(target.checkoutID == checkoutID)
        #expect(target.memberID == available)
        #expect(selectedCheckout == checkoutID)
        #expect(focusedMember?.member == available)
        await #expect(throws: WorkspaceAutomationError.memberUnavailable) {
            try await service.focusMember(checkoutID: checkoutID, memberID: unavailable)
        }
        await #expect(throws: WorkspaceAutomationError.memberRequired) {
            try await service.memberTarget(checkoutID: checkoutID, memberID: nil)
        }
    }

    @Test func automationAppliesReadOnlyReconciliationBeforeReportingAvailability() async throws {
        let checkoutID = UUID()
        let memberID = UUID()
        let store = try await makeStore(state: .init(checkouts: [
            checkout(id: checkoutID, members: [
                member(id: memberID, projectID: "project-a", availability: .available),
            ]),
        ]))
        let service = WorkspaceAutomationService(
            store: store,
            isEnabled: { true },
            observer: AutomationObserver(result: .missing)
        )

        let shown = try await service.showCheckout(id: checkoutID)

        #expect(shown.checkout.members.first?.availability == .missing)
        await #expect(throws: WorkspaceAutomationError.memberUnavailable) {
            try await service.memberTarget(checkoutID: checkoutID, memberID: memberID)
        }
        #expect(try await loaded(store).checkouts.first?.members.first?.availability == .available)
    }

    @Test func disabledOrUnreadableWorkspaceStateReturnsStableErrors() async throws {
        let disabled = WorkspaceAutomationService(store: WorkspaceStore(url: tempURL()), isEnabled: { false })
        await #expect(throws: WorkspaceAutomationError.disabled) {
            try await disabled.listCheckouts()
        }

        let unreadableURL = tempURL()
        try FileManager.default.createDirectory(at: unreadableURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"version":1,"checkouts":["bad"]}"#.write(to: unreadableURL, atomically: true, encoding: .utf8)
        let unreadable = WorkspaceAutomationService(store: WorkspaceStore(url: unreadableURL), isEnabled: { true })
        do {
            _ = try await unreadable.listCheckouts()
            Issue.record("expected recovery required")
        } catch let error as WorkspaceAutomationError {
            #expect(error.code == "workspace_recovery_required")
            #expect(error.exitCode == 3)
        }
    }

    private func loaded(_ store: WorkspaceStore) async throws -> WorkspaceStateFile {
        guard case .loaded(let state) = await store.load() else {
            throw WorkspaceAutomationError.recoveryRequired
        }
        return state
    }

    private func makeStore(state: WorkspaceStateFile) async throws -> WorkspaceStore {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let store = WorkspaceStore(url: url)
        try await store.checkpoint(state)
        return store
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-workspace-automation-\(UUID().uuidString)")
            .appendingPathComponent("workspaces.json")
    }

    private func checkout(
        id: UUID = UUID(),
        workspaceID: UUID? = nil,
        archivedAt: Date? = nil,
        members: [WorkspaceCheckoutMember]
    ) -> WorkspaceCheckout {
        WorkspaceCheckout(
            id: id,
            workspaceID: workspaceID,
            fallbackWorkspaceName: "Workspace",
            executionLocation: .local,
            branch: "feature",
            rootPath: "/tmp/workspace",
            archivedAt: archivedAt,
            members: members
        )
    }

    private func member(
        id: UUID = UUID(),
        projectID: String,
        availability: WorkspaceCheckoutMemberAvailability
    ) -> WorkspaceCheckoutMember {
        WorkspaceCheckoutMember(
            id: id,
            workspaceMemberID: UUID(),
            projectID: projectID,
            fallbackProjectName: projectID,
            fallbackRepositoryRoot: "/repos/\(projectID)",
            worktreePath: "/tmp/workspace/\(projectID)",
            availability: availability,
            checkpoint: availability == .available ? .setupComplete : .failed
        )
    }
}

private struct AutomationObserver: WorkspaceCheckoutObserving {
    var result: WorkspaceCheckoutMemberObservation = .missing
    var results: [UUID: WorkspaceCheckoutMemberObservation] = [:]

    func observe(_ member: WorkspaceCheckoutMember, in checkout: WorkspaceCheckout) async -> WorkspaceCheckoutMemberObservation {
        results[member.id] ?? result
    }
}
