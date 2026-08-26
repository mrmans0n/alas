import AppKit
import Testing
@testable import Alas

@MainActor
struct CopyFeedbackStateTests {
    @Test func copyingWritesPathAndShowsFeedback() {
        let pasteboard = NSPasteboard(name: .init("CopyFeedbackStateTests"))
        let state = CopyFeedbackState()

        state.copy("Alas/Sources/App.swift", to: pasteboard)

        #expect(pasteboard.string(forType: .string) == "Alas/Sources/App.swift")
        #expect(state.message == "Copied")
    }
}
