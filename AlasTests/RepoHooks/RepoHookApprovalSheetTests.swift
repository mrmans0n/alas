import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Alas

@MainActor
@Suite("Repository hook approval sheet")
struct RepoHookApprovalSheetTests {
    @Test("long hook text stays within a bounded sheet height")
    func longHookTextDoesNotExpandTheApprovalSheet() {
        let text = String(repeating: "echo session open\n", count: 1_000)
        let bytes = Data(text.utf8)
        let hook = RepoHook(
            event: .sessionOpen,
            source: .local,
            bytes: bytes,
            text: text,
            hash: RepoHookTrust.hash(event: .sessionOpen, bytes: bytes)
        )
        let request = RepoHookApprovalRequest(
            id: UUID(),
            content: .hook(hook),
            context: .sessionOpen
        )
        let sheet = RepoHookApprovalSheet(request: request, queue: RepoHookApprovalQueue())
        let controller = NSHostingController(rootView: sheet)

        let size = controller.sizeThatFits(in: NSSize(width: 620, height: CGFloat.greatestFiniteMagnitude))

        #expect(size.height < 600)
    }
}
