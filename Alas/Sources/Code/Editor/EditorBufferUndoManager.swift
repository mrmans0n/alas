import AppKit

/// Native, synchronous buffer history between shared workspace boundaries.
/// A boundary stays on its original side while its asynchronous action runs.
@MainActor
final class EditorBufferUndoManager: UndoManager {
    private struct Marker {
        let id: UUID
        let beforePosition: Int
        let activate: (Bool) -> Void
    }

    private final class Segment {
        let manager = UndoManager()
        var position = 0
        init() { manager.groupsByEvent = false }
    }

    private var segments: [Segment] = [Segment()]
    private var markers: [Marker] = []
    private var cursor = 0
    var workspaceActionInFlight = false
    private var current: UndoManager { segments[cursor].manager }

    override init() {
        super.init()
        // AppKit's private text coalescing also consults this manager. Only
        // buffer-targeted registrations in the native segments are allowed.
        super.disableUndoRegistration()
    }

    override var canUndo: Bool { !workspaceActionInFlight && (current.canUndo || cursor > 0) }
    override var canRedo: Bool { !workspaceActionInFlight && (current.canRedo || cursor < markers.count) }
    override var isUndoing: Bool { current.isUndoing }
    override var isRedoing: Bool { current.isRedoing }
    override var groupingLevel: Int { current.groupingLevel }
    override var undoActionName: String { current.canUndo ? current.undoActionName : cursor > 0 ? "Workspace Edit" : "" }
    override var redoActionName: String { current.canRedo ? current.redoActionName : cursor < markers.count ? "Workspace Edit" : "" }
    override var undoMenuItemTitle: String { canUndo ? "Undo \(undoActionName)" : "Undo" }
    override var redoMenuItemTitle: String { canRedo ? "Redo \(redoActionName)" : "Redo" }

    override func beginUndoGrouping() { current.beginUndoGrouping() }
    override func endUndoGrouping() { current.endUndoGrouping() }
    override func setActionName(_ actionName: String) {
        guard current.groupingLevel > 0 || current.canUndo || current.canRedo else { return }
        current.setActionName(actionName)
    }

    override func undo() {
        guard !workspaceActionInFlight else { return }
        if current.canUndo { current.undo() }
        else if cursor > 0 { markers[cursor - 1].activate(false) }
    }

    override func redo() {
        guard !workspaceActionInFlight else { return }
        if current.canRedo { current.redo() }
        else if cursor < markers.count { markers[cursor].activate(true) }
    }

    override func removeAllActions() {
        segments = [Segment()]
        markers.removeAll()
        cursor = 0
        super.removeAllActions()
    }

    func registerBufferUndo(target: EditorBuffer, actionName: String, handler: @escaping (EditorBuffer) -> Void) {
        // Count reciprocal registrations synchronously. Shared redo stays
        // available after an intervening local edit is itself undone.
        segments[cursor].position += current.isUndoing ? -1 : 1
        let needsGroup = current.groupingLevel == 0
        if needsGroup { current.beginUndoGrouping() }
        current.registerUndo(withTarget: target, handler: handler)
        current.setActionName(actionName)
        if needsGroup { current.endUndoGrouping() }
    }

    func installMarker(_ id: UUID, activate: @escaping (Bool) -> Void) {
        guard !markers.contains(where: { $0.id == id }), current.groupingLevel == 0 else { return }
        if cursor < markers.count {
            markers.removeSubrange(cursor...)
            segments.removeSubrange((cursor + 1)...)
        }
        // Native UndoManager has no public redo-only reset. A temporary
        // registration invalidates redo without discarding earlier undo.
        let sentinel = NSObject()
        current.beginUndoGrouping()
        current.registerUndo(withTarget: sentinel) { _ in }
        current.endUndoGrouping()
        current.removeAllActions(withTarget: sentinel)
        markers.append(Marker(id: id, beforePosition: segments[cursor].position, activate: activate))
        segments.append(Segment())
        cursor += 1
    }

    func isAtMarker(_ id: UUID, redo: Bool) -> Bool {
        if redo {
            return cursor < markers.count && markers[cursor].id == id
                && segments[cursor].position == markers[cursor].beforePosition
        }
        return !current.canUndo && cursor > 0 && markers[cursor - 1].id == id
    }

    func completeMarker(_ id: UUID, redo: Bool) {
        guard isAtMarker(id, redo: redo) else { return }
        cursor += redo ? 1 : -1
    }
}
