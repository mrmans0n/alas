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

    nonisolated static func operationMask(
        for context: NSDraggingContext,
        hasInternalPayload: Bool,
        hasExternalRepresentation: Bool
    ) -> NSDragOperation {
        switch context {
        case .outsideApplication:
            return hasExternalRepresentation ? .copy : []
        case .withinApplication:
            return hasInternalPayload ? .copy : []
        @unknown default:
            return hasExternalRepresentation ? .copy : []
        }
    }

    /// Two flavors: the file URL for apps that open files, and the absolute
    /// POSIX path for terminals and text fields.
    nonisolated static func pasteboardItem(for prepared: DragOutPreparedItem) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        if let payload = prepared.dropPayload,
           let data = payload.encoded() {
            item.setData(data, forType: .alasDropPayload)
        }
        if let url = prepared.fileURL {
            item.setString(url.absoluteString, forType: .fileURL)
        }
        if let text = prepared.publicText {
            item.setString(text, forType: .string)
        }
        return item
    }

    nonisolated func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        let pasteboard = session.draggingPasteboard
        return Self.operationMask(
            for: context,
            hasInternalPayload: pasteboard.availableType(from: [.alasDropPayload]) != nil,
            hasExternalRepresentation: pasteboard.availableType(from: [.fileURL, .string]) != nil
        )
    }

    func begin(prepared: DragOutPreparedItem, event: NSEvent, in view: NSView) {
        let item = NSDraggingItem(pasteboardWriter: Self.pasteboardItem(for: prepared))
        let icon = dragIcon(for: prepared)
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

    private func dragIcon(for prepared: DragOutPreparedItem) -> NSImage {
        if let url = prepared.fileURL {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        let symbolName: String
        switch prepared.dropPayload {
        case .commitSHA: symbolName = "number"
        case .file: symbolName = "doc"
        case nil: symbolName = "doc"
        }
        return NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) ?? NSImage()
    }
}
