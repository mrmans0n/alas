import AppKit
import SwiftUI

/// How the `/btw` card is placed, read by its chrome.
struct ACPSideQuestionCardLayout: Equatable {
    var dock: ACPSideQuestionDock = .composer
    /// The height the user chose; the card hugs shorter content. In the side
    /// dock, the column's height.
    var cap: CGFloat = ACPSideQuestionDockLayout.defaultHeight
    /// The most the card may grow to while the agent waits on the user.
    var limit: CGFloat = ACPSideQuestionDockLayout.defaultHeight
}

/// Lets the card's header move it to another dock.
struct ACPSideQuestionDockActions {
    var onSelectDock: (ACPSideQuestionDock) -> Void = { _ in }
    /// The global pointer location while the header is dragged.
    var onHeaderDrag: (CGPoint) -> Void = { _ in }
    /// The header was released: snap to the zone under the last location
    /// (outside every zone the card stays put), then clear the drag.
    var onHeaderDrop: () -> Void = {}
    /// The drag ended without a release (cancelled, or the card went away):
    /// clear it, never snap. A no-op when nothing is being dragged.
    var onHeaderDragCancel: () -> Void = {}
}

extension EnvironmentValues {
    @Entry var acpSideQuestionCardLayout = ACPSideQuestionCardLayout()
    @Entry var acpSideQuestionDockActions = ACPSideQuestionDockActions()
}

extension ACPSideQuestionDock {
    var title: String {
        switch self {
        case .composer: "Above composer"
        case .top: "Top"
        case .side: "Side"
        }
    }

    var symbol: String {
        switch self {
        case .composer: "rectangle.bottomthird.inset.filled"
        case .top: "rectangle.topthird.inset.filled"
        case .side: "rectangle.righthalf.inset.filled"
        }
    }
}

/// A grab bar on the card's top or bottom edge. Unlike `DragHandle` it draws
/// no divider column, since it floats over the transcript.
struct ACPSideQuestionResizeGrip: View {
    /// Vertical translation since drag start, in global space; see `DragHandle`.
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: () -> Void

    @State private var hovering = false
    @State private var dragging = false
    @State private var cursorPushed = false
    @Environment(\.theme) private var theme

    var body: some View {
        Capsule()
            .fill(theme.color("warn").opacity(hovering || dragging ? 0.8 : 0.35))
            .frame(width: 36, height: 4)
            .frame(width: 120, height: 12)
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
                        onDragChanged(value.translation.height)
                    }
                    .onEnded { _ in
                        dragging = false
                        onDragEnded()
                        if !hovering { popCursor() }
                    }
            )
            .onDisappear { popCursor() }
            .help("Drag to resize")
    }

    private func pushCursor() {
        guard !cursorPushed else { return }
        NSCursor.resizeUpDown.push()
        cursorPushed = true
    }

    private func popCursor() {
        guard cursorPushed else { return }
        NSCursor.pop()
        cursorPushed = false
    }
}

/// Dashed targets shown while the card's header is dragged. The zones come
/// from `ACPSideQuestionDockLayout`, so what's drawn is what a drop hits.
struct ACPSideQuestionDropZones: View {
    let size: CGSize
    let highlighted: ACPSideQuestionDock?

    @Environment(\.theme) private var theme

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(ACPSideQuestionDock.allCases, id: \.self) { dock in
                let rect = ACPSideQuestionDockLayout.zone(for: dock, in: size).insetBy(dx: 8, dy: 8)
                let isOn = dock == highlighted
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.color("accent").opacity(isOn ? 0.16 : 0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10).strokeBorder(
                            theme.color("accent").opacity(isOn ? 0.9 : 0.4),
                            style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                        )
                    )
                    .overlay {
                        Label(dock.title, systemImage: dock.symbol)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.color("accent"))
                    }
                    .frame(width: max(0, rect.width), height: max(0, rect.height))
                    .offset(x: rect.minX, y: rect.minY)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}
