import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Alas

@Suite("Repo MCP trust banner presentation")
@MainActor
struct RepoMCPTrustBannerPresentationTests {
    @Test func reviewSheetOwnsRuntimeHookApprovals() async throws {
        let state = AppState(store: MemoryStore(), restoreActiveTabsOnStartup: false)
        let server = ProjectMCPServer(
            id: "repo:linear",
            name: "linear",
            transport: .http(url: "https://mcp.example.com", headers: [])
        )
        let banner = RepoMCPTrustBanner(
            pendingServers: [server],
            approvalQueue: state.repoHookApprovalQueue,
            onApproveAll: {},
            onDeclineAll: {}
        )
        .environment(\.theme, try ThemeStore().current)
        let controller = NSHostingController(rootView: banner)
        controller.view.frame = NSRect(x: 0, y: 0, width: 520, height: 160)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 160),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        let reviewButton = try #require(allSubviews(of: controller.view).compactMap { $0 as? NSButton }.first {
            $0.title == "Review…"
        })
        reviewButton.performClick(nil)

        let bytes = Data("echo session open".utf8)
        let hook = RepoHook(
            event: .sessionOpen,
            source: .local,
            bytes: bytes,
            text: String(decoding: bytes, as: UTF8.self),
            hash: RepoHookTrust.hash(event: .sessionOpen, bytes: bytes)
        )
        let task = Task {
            await state.repoHookApprovalQueue.requestDecision(
                hook: hook,
                projectID: "project",
                context: .sessionOpen
            )
        }
        await waitUntil { state.repoHookApprovalQueue.activeDialogRequest != nil }
        let nestedRequest = state.repoHookApprovalQueue.activeDialogRequest
        state.repoHookApprovalQueue.decide(.approve)

        #expect(nestedRequest?.context == .sessionOpen)
        #expect(await task.value == .approve)
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(1)
        while !condition(), Date() < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
