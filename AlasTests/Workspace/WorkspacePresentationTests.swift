import AppKit
import SwiftUI
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct WorkspacePresentationTests {
    @Test func workspaceSidebarFitsNarrowAndWideColumns() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(url: directory.appendingPathComponent("workspaces.json"))
        let workspace = Workspace(name: "Platform release coordination", executionLocation: .local, members: [])
        var checkout = checkout(memberCount: 2)
        checkout.workspaceID = workspace.id
        checkout.branch = "feature/a-long-branch-name-for-coordinated-changes"
        try await store.checkpoint(.init(workspaces: [workspace], checkouts: [checkout]))
        let state = AppState(store: MemoryStore(), restoreActiveTabsOnStartup: false, workspaceStore: store)
        await state.setWorkspacesEnabled(true, persistConfig: false)
        state.spacesManager.setTypedMembers([.workspace(workspace.id)], forSpace: state.spacesManager.activeSpaceId)
        state.selectWorkspaceCheckout(id: checkout.id)

        for width in [CGFloat(220), CGFloat(320)] {
            let size = try render(
                WorkspaceSidebarTree(state: state) { _ in EmptyView() }.frame(width: width),
                named: "workspace-sidebar-\(Int(width))"
            )
            #expect(size.width == width)
            #expect(size.height < 220)
        }
    }

    @Test func checkoutInspectorKeepsItsSizeWithManyRepositories() throws {
        let compact = try render(
            WorkspaceCheckoutDetailView(model: .init(checkout: checkout(memberCount: 2))),
            named: "workspace-checkout-details"
        )
        let large = try render(
            WorkspaceCheckoutDetailView(model: .init(checkout: checkout(memberCount: 30))),
            named: "workspace-checkout-many-repositories"
        )

        #expect(compact.width == 560)
        #expect(large == compact)
        #expect(large.height < 640)
    }

    @Test func definitionDialogsKeepRepositoryListsWithinSheetBounds() throws {
        let state = AppState(store: MemoryStore(), restoreActiveTabsOnStartup: false)
        let newSize = try render(
            NewWorkspaceDialog(state: state, presented: .constant(true)),
            named: "workspace-new"
        )
        let workspace = Workspace(
            name: "Release coordination",
            executionLocation: .local,
            members: (0..<30).map { index in
                WorkspaceMember(
                    projectID: "project-\(index)",
                    fallbackProjectName: "Repository \(index) with a long descriptive name",
                    fallbackRepositoryRoot: "/Users/developer/Projects/platform/services/repository-\(index)"
                )
            }
        )
        let editSize = try render(
            EditWorkspaceDialog(state: state, workspace: workspace, presented: .constant(true)),
            named: "workspace-edit"
        )
        let checkoutSize = try render(
            CreateWorkspaceCheckoutDialog(state: state, workspace: workspace, presented: .constant(true)),
            named: "workspace-create-checkout"
        )

        #expect(newSize.width == 480)
        #expect(editSize.width == 480)
        #expect(editSize.height < 640)
        #expect(checkoutSize.width == 560)
        #expect(checkoutSize.height < 640)
    }

    @Test func memberActionsDoNotForceLongNamesBeyondInspectorWidth() throws {
        let member = WorkspaceCheckoutMemberRowModel(
            id: UUID(),
            title: "A repository with a long name that should wrap within the inspector",
            detail: "/Users/developer/Projects/platform/services/repository-with-a-long-directory-name",
            status: .identityConflict,
            actions: [
                .init(.findExisting, title: "Find Existing"),
                .init(.deleteMember, title: "Delete Snapshot", isDestructive: true),
            ]
        )
        let size = try render(
            WorkspaceCheckoutMemberRow(row: member).frame(width: 516),
            named: "workspace-member-long-name"
        )

        #expect(size.width == 516)
        #expect(size.height < 160)
    }

    private func render<V: View>(_ view: V, named name: String) throws -> CGSize {
        let theme = try ThemeStore().current
        let controller = NSHostingController(rootView: view.environment(\.theme, theme).background(theme.color("bg-1")))
        // Initial selection can expand the sidebar during its first layout.
        for _ in 0..<3 {
            controller.view.frame = NSRect(origin: .zero, size: controller.view.fittingSize)
            controller.view.layoutSubtreeIfNeeded()
        }
        let size = controller.view.fittingSize
        let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        Attachment.record(png, named: "\(name).png")
        return size
    }

    private func checkout(memberCount: Int) -> WorkspaceCheckout {
        WorkspaceCheckout(
            workspaceID: UUID(),
            fallbackWorkspaceName: "Release coordination",
            executionLocation: .local,
            branch: "feature/coordinated-release",
            rootPath: "/Users/developer/Workspaces/coordinated-release",
            members: (0..<memberCount).map { index in
                WorkspaceCheckoutMember(
                    workspaceMemberID: UUID(), projectID: "project-\(index)",
                    fallbackProjectName: "Repository \(index)",
                    fallbackRepositoryRoot: "/Users/developer/Projects/repository-\(index)",
                    worktreePath: "/Users/developer/Workspaces/coordinated-release/repository-\(index)",
                    availability: .available, checkpoint: .setupComplete
                )
            }
        )
    }

    private struct MemoryStore: PersistenceStoreProtocol {
        func write<T: Encodable>(_: T, to _: URL) throws {}
        func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? { nil }
    }
}
