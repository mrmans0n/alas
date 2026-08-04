import AppKit

/// Drag source for files dragged out of Alas.
///
/// The operation mask is the whole reason this is AppKit rather than SwiftUI's
/// `.draggable`: pinning outside-app drags to `.copy` is what guarantees a
/// Finder drop can never move a file out of a worktree.
@MainActor
final class DragOutSession: NSObject, NSDraggingSource {
    static let shared = DragOutSession()

    /// Drag image edge length, in points.
    private static let iconSize: CGFloat = 32

    nonisolated static func operationMask(for context: NSDraggingContext) -> NSDragOperation {
        switch context {
        case .outsideApplication: return .copy
        case .withinApplication: return []
        @unknown default: return .copy
        }
    }

    /// Two flavors: the file URL for apps that open files, and the absolute
    /// POSIX path for terminals and text fields.
    nonisolated static func pasteboardItem(for url: URL) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        item.setString(url.path, forType: .string)
        return item
    }

    nonisolated func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        Self.operationMask(for: context)
    }

    func begin(url: URL, event: NSEvent, in view: NSView) {
        let item = NSDraggingItem(pasteboardWriter: Self.pasteboardItem(for: url))
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        let size = NSSize(width: Self.iconSize, height: Self.iconSize)
        icon.size = size
        let origin = view.convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(
            NSRect(
                x: origin.x - size.width / 2,
                y: origin.y - size.height / 2,
                width: size.width,
                height: size.height
            ),
            contents: icon
        )
        view.beginDraggingSession(with: [item], event: event, source: self)
    }
}
