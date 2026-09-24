import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Alas

@Suite("LSP install progress approval presentation")
@MainActor
struct LSPInstallProgressSheetPresentationTests {
    @Test func sheetOwnsRuntimeHookApprovals() async throws {
        let state = AppState(store: MemoryStore(), restoreActiveTabsOnStartup: false)
        let sheet = LSPInstallProgressSheet(
            installer: state.lspInstaller,
            approvalQueue: state.repoHookApprovalQueue
        ) { _ in }
        .environment(\.theme, try ThemeStore().current)
        let controller = NSHostingController(rootView: sheet)
        controller.view.frame = NSRect(x: 0, y: 0, width: 640, height: 420)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

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

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(1)
        while !condition(), Date() < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
