import SwiftUI

struct DragHandle: View {
    enum Axis { case horizontal, vertical }

    let axis: Axis
    /// Cumulative translation along `axis` since drag start, measured in the
    /// global coordinate space. Global space stays fixed while the handle
    /// moves under the cursor; measuring in `.local` space fed the handle's
    /// own movement back into the gesture and made dividers oscillate.
    /// Callers anchor on the width captured at drag start:
    /// `width = clamp(startWidth ± translation)`.
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: () -> Void
    private let legacyDeltaMode: Bool

    @State private var hovering = false
    @State private var dragging = false
    @State private var cursorPushed = false
    /// Only used when constructed via the legacy `onDrag:` initializer, to
    /// convert cumulative translation back into a per-event delta. Backed
    /// by `@State` so it survives body re-evaluations mid-drag — a plain
    /// stored property reset every time the view struct is reconstructed
    /// (e.g. after a callback mutates observable state), which silently
    /// reintroduced full-cumulative deltas instead of incremental ones.
    @State private var legacyLastTranslation: CGFloat = 0

    init(
        axis: Axis,
        onDragChanged: @escaping (CGFloat) -> Void,
        onDragEnded: @escaping () -> Void = {}
    ) {
        self.axis = axis
        self.onDragChanged = onDragChanged
        self.onDragEnded = onDragEnded
        self.legacyDeltaMode = false
    }

    /// Transitional adapter for the legacy per-event-delta API. Remaining
    /// call sites migrate to `onDragChanged` in a follow-up task; delete
    /// this initializer (and `legacyDeltaMode`/`legacyLastTranslation`)
    /// once nothing uses it.
    init(axis: Axis, onDrag: @escaping (CGFloat) -> Void, onEnded: @escaping () -> Void = {}) {
        self.axis = axis
        self.onDragChanged = onDrag
        self.onDragEnded = onEnded
        self.legacyDeltaMode = true
    }

    var body: some View {
        VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
            .frame(
                width: axis == .horizontal ? 6 : nil,
                height: axis == .vertical ? 6 : nil
            )
            .contentShape(Rectangle())
            .onHover { isHovering in
                hovering = isHovering
                if isHovering {
                    pushCursor()
                } else if !dragging {
                    popCursor()
                }
            }
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        dragging = true
                        let translation = axis == .horizontal
                            ? value.translation.width
                            : value.translation.height
                        if legacyDeltaMode {
                            let delta = translation - legacyLastTranslation
                            legacyLastTranslation = translation
                            onDragChanged(delta)
                        } else {
                            onDragChanged(translation)
                        }
                    }
                    .onEnded { _ in
                        dragging = false
                        if legacyDeltaMode {
                            legacyLastTranslation = 0
                        }
                        onDragEnded()
                        if !hovering {
                            popCursor()
                        }
                    }
            )
            .onDisappear {
                if cursorPushed {
                    popCursor()
                }
            }
    }

    private func pushCursor() {
        guard !cursorPushed else { return }
        switch axis {
        case .horizontal: NSCursor.resizeLeftRight.push()
        case .vertical:   NSCursor.resizeUpDown.push()
        }
        cursorPushed = true
    }

    private func popCursor() {
        guard cursorPushed else { return }
        NSCursor.pop()
        cursorPushed = false
    }

    nonisolated static func clamp(value: Double, min minVal: Double, max maxVal: Double) -> Double {
        max(minVal, min(maxVal, value))
    }
}
