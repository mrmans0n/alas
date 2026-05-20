import Testing
import SwiftUI
import AppKit
@testable import Alas

@Suite(.serialized)
@MainActor
struct InlineErrorStripTests {
    private func currentTheme() -> Theme {
        try! ThemeStore().current
    }

    @Test func compactErrorStripRendersLongMessageWithoutCrashing() {
        let view = InlineErrorStrip(message: longErrorMessage, onDismiss: {})
            .environment(\.theme, currentTheme())
        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 420, height: 80)
        controller.view.layoutSubtreeIfNeeded()

        #expect(controller.view != nil)
    }

    @Test func expandedErrorStripAllowsMoreVerticalSpaceForLongMessage() {
        let compact = hostingHeight(for: InlineErrorStrip(
            message: longErrorMessage,
            onDismiss: {},
            initiallyExpanded: false
        ))
        let expanded = hostingHeight(for: InlineErrorStrip(
            message: longErrorMessage,
            onDismiss: {},
            initiallyExpanded: true
        ))

        #expect(expanded > compact)
    }

    private func hostingHeight(for view: InlineErrorStrip) -> CGFloat {
        let themedView = view.environment(\.theme, currentTheme())
        let controller = NSHostingController(rootView: themedView)
        controller.view.frame = NSRect(x: 0, y: 0, width: 420, height: 400)
        controller.view.layoutSubtreeIfNeeded()
        return controller.view.fittingSize.height
    }

    private var longErrorMessage: String {
        """
        fatal: unable to create commit
        error: gpg failed to sign the data
        hint: run `git config --global user.signingkey` and verify the key is available
        stderr: signing failed after the pinentry helper exited before returning a passphrase
        """
    }
}
