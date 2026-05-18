import AppKit
import SwiftUI

final class TabDragWindowShieldView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
}

struct TabDragWindowShield: NSViewRepresentable {
    func makeNSView(context: Context) -> TabDragWindowShieldView {
        TabDragWindowShieldView()
    }

    func updateNSView(_ nsView: TabDragWindowShieldView, context: Context) {}
}
