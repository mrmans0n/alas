#if DEBUG
import AlasCore
import AppKit
import SwiftUI

/// Design-capture targets that show a view no click can reach on a demo profile: a scripted
/// checkout, or a gallery of scripted VM tab states. Each one is drawn in a borderless panel
/// over the main window, which `DesignCaptureCode.snapshotWindows` composites into window.png.
/// Nothing is read from or written to the user's workspaces, registry or VM images. Debug builds
/// only, and only on a capture profile.
///
/// - workspace-checkout: the checkout details sheet of a three-repository checkout (one ready,
///   one with a failed setup, one whose worktree is missing) with a stop request pending.
/// - workspace-checkout-bottom: the same sheet scrolled to its work items and review roll-ups.
@MainActor
enum DesignCaptureWorkspace {
    static let targets: Set<String> = ["workspace-checkout", "workspace-checkout-bottom"]

    private static var panel: NSPanel?

    /// Only an instance capture.sh launched on a demo profile may show scripted content; another
    /// Debug instance also receives the distributed capture notification and must ignore it.
    static var isCaptureInstance: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["ALAS_DESIGN_CAPTURE"] == "1" && env["ALAS_APP_SUPPORT_DIR"] != nil
    }

    static func open(_ target: String, state: AppState) {
        guard isCaptureInstance, targets.contains(target) else { return }
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(30)
            while state.projects.isEmpty {
                guard Date() < deadline else { return }
                try? await Task.sleep(for: .milliseconds(200))
            }
            let content = WorkspaceCheckoutDetailView(model: checkoutModel())
                .environment(\.theme, state.themeStore.current)
                .environment(\.designScale, .resolved(for: state.config.density))
            present(content)
            if target == "workspace-checkout-bottom" { scrollToBottom() }
        }
    }

    /// The sheet's body scrolls; this shows what sits below the first screenful.
    private static func scrollToBottom() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            func find(_ view: NSView) -> NSScrollView? {
                if let scroll = view as? NSScrollView { return scroll }
                for sub in view.subviews { if let found = find(sub) { return found } }
                return nil
            }
            guard let root = panel?.contentView, let scroll = find(root), let document = scroll.documentView else { return }
            let clip = scroll.contentView
            let y = document.isFlipped ? max(0, document.bounds.height - clip.bounds.height) : 0
            clip.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(clip)
        }
    }

    /// Draws `content` centered over the main window, at the size it asks for.
    static func present<Content: View>(_ content: Content) {
        guard let window = NSApp.windows.filter({ $0.isVisible && $0.parent == nil && $0.contentView != nil && $0.frame.width > 600 })
            .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { return }
        panel?.parent?.removeChildWindow(panel!)
        panel?.orderOut(nil)
        let host = NSHostingView(rootView: content)
        let size = host.fittingSize
        let next = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        next.contentView = host
        next.hasShadow = true
        next.hidesOnDeactivate = false
        next.setFrame(NSRect(x: window.frame.midX - size.width / 2, y: window.frame.midY - size.height / 2, width: size.width, height: size.height), display: true)
        window.addChildWindow(next, ordered: .above)
        next.orderFront(nil)
        panel = next
    }

    // MARK: - Scripted checkout

    private static func checkoutModel() -> WorkspaceCheckoutDetailModel {
        let root = "/Users/demo/code/checkouts/billing-export"
        func member(_ name: String, availability: WorkspaceCheckoutMemberAvailability, checkpoint: WorkspaceCheckoutCheckpoint) -> WorkspaceCheckoutMember {
            WorkspaceCheckoutMember(
                workspaceMemberID: UUID(), projectID: name, fallbackProjectName: name,
                fallbackRepositoryRoot: "/Users/demo/code/\(name)", worktreePath: "\(root)/\(name)",
                availability: availability, checkpoint: checkpoint)
        }
        let api = member("lantern-api", availability: .available, checkpoint: .setupComplete)
        let web = member("lantern-web", availability: .available, checkpoint: .failed)
        let mobile = member("lantern-mobile", availability: .missing, checkpoint: .setupComplete)
        let checkout = WorkspaceCheckout(
            workspaceID: UUID(), fallbackWorkspaceName: "Billing export", executionLocation: .local,
            branch: "feat/billing-export", rootPath: root, createdAt: Date().addingTimeInterval(-3 * 86_400),
            members: [api, web, mobile],
            diagnostics: [
                WorkspaceDiagnostic(
                    severity: .error, message: "Workspace setup failed for lantern-web.", memberID: web.id,
                    detail: "npm ci exited with status 1: EACCES permission denied, mkdir '/usr/local/lib/node_modules'"),
            ],
            workItems: [WorkItemSnapshot(title: "Export invoices as CSV from the billing dashboard", providerID: "linear", hostingMemberID: api.id)],
            stopAfterCurrentOperations: true)
        return WorkspaceCheckoutDetailModel(checkout: checkout, reviewRollup: rollup(for: checkout))
    }

    private static func rollup(for checkout: WorkspaceCheckout) -> WorkspaceMemberReviewRollup {
        let when = Date().addingTimeInterval(-3_600)
        func entries(_ published: Int, _ total: Int) -> [GGStackEntry] {
            (1...total).map {
                GGStackEntry(
                    position: $0, sha: String(format: "%07x", 0xabc000 + $0), title: "Commit \($0)", ggId: "c-\($0)",
                    prNumber: $0 <= published ? 400 + $0 : nil, prState: $0 <= published ? .open : nil)
            }
        }
        func stack(_ published: Int, _ total: Int) -> GGStack? {
            let list = entries(published, total).map { e -> [String: Any] in
                var d: [String: Any] = ["position": e.position, "sha": e.sha, "title": e.title, "ggId": e.ggId ?? "", "approved": false, "isCurrent": false]
                if let pr = e.prNumber { d["prNumber"] = pr
                d["prState"] = "open" }
                return d
            }
            let object: [String: Any] = ["name": "billing-export", "base": "main", "totalCommits": total, "syncedCommits": published, "entries": list]
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
            return try? JSONDecoder().decode(GGStack.self, from: data)
        }
        func record(_ member: WorkspaceCheckoutMember, _ n: Int) -> ReviewSessionRecord {
            let target = ReviewSessionTarget.localChanges(
                worktreeID: member.worktreePath, repositoryPath: URL(fileURLWithPath: member.worktreePath), scope: n == 0 ? .all : .staged)
            return ReviewSessionRecord(id: target.id, target: target, createdAt: when, updatedAt: when)
        }
        let rows = checkout.members.enumerated().map { index, member -> WorkspaceMemberReviewRollup.Member in
            let available = member.availability == .available
            let reviews = available && index == 0 ? [record(member, 0)] : []
            let stack = available ? stack(index == 0 ? 2 : 0, index == 0 ? 3 : 1) : nil
            return WorkspaceMemberReviewRollup.Member(
                memberID: member.id, projectID: member.projectID, title: member.fallbackProjectName,
                availability: member.availability, worktreeID: member.worktreePath, reviews: reviews, ggStack: stack,
                unpublishedStackEntries: stack?.entries.filter { $0.prNumber == nil } ?? [],
                reviewActions: reviews.map { WorkspaceReviewAction(memberID: member.id, worktreeID: member.worktreePath, reviewSessionID: $0.id) })
        }
        return WorkspaceMemberReviewRollup(members: rows)
    }
}
#endif
