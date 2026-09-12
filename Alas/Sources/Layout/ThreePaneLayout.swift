import SwiftUI

struct ThreePaneLayout<Sidebar: View, Center: View, Right: View>: View {
    @Binding var sidebarWidth: Double
    @Binding var rightWidth: Double
    let sidebarVisible: Bool
    let rightVisible: Bool
    /// Width of the rail strip drawn in place of a hidden right pane. `nil`
    /// hides the right pane entirely, which is the long-standing behavior.
    var rightCollapsedWidth: Double? = nil
    let onWidthsChanged: () -> Void
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let center: (_ rightVisible: Bool) -> Center
    @ViewBuilder let right: (_ collapsed: Bool) -> Right

    // Gutter drags mutate only this transient state, so the drag invalidates
    // just this view. The bindings write into app-wide observable config —
    // touching them per mouse-move re-rendered every config reader — so they
    // are written once, on drag end.
    @State private var transientSidebarWidth: Double?
    @State private var transientRightWidth: Double?
    @State private var sidebarDragStartWidth: Double?
    @State private var rightDragStartWidth: Double?
    @Environment(\.displayScale) private var displayScale

    private let sidebarMin: Double = 200
    private let sidebarMax: Double = 420
    private let rightMin: Double = 240
    private let rightMax: Double = 560
    private let centerMin: Double = 400
    private let dividerWidth: Double = 6

    var body: some View {
        GeometryReader { proxy in
            let railSizing = RightRailSizing.calculate(
                availableWidth: Double(proxy.size.width),
                preferredSidebarWidth: transientSidebarWidth ?? sidebarWidth,
                preferredRightWidth: transientRightWidth ?? rightWidth,
                sidebarPreferredVisible: sidebarVisible,
                rightPreferredVisible: rightVisible,
                railWidth: rightCollapsedWidth,
                configuration: ThreePaneSizing.Configuration(
                    sidebarMin: sidebarMin,
                    sidebarMax: sidebarMax,
                    rightMin: rightMin,
                    rightMax: rightMax,
                    centerMin: centerMin,
                    dividerWidth: dividerWidth
                )
            )
            let sizing = railSizing.sizing

            // Pixel-align the side panes; the center absorbs the ≤1px
            // rounding remainder so the row still fills the window exactly.
            let scale = Double(displayScale)
            let alignedSidebarWidth = PaneDragMath.pixelAligned(sizing.sidebarWidth, scale: scale)
            let alignedRightWidth = PaneDragMath.pixelAligned(sizing.rightWidth, scale: scale)
            let dividerTotal = (sizing.sidebarVisible ? dividerWidth : 0)
                + (sizing.rightVisible ? dividerWidth : 0)
            let alignedCenterWidth = max(
                0,
                Double(proxy.size.width) - dividerTotal - railSizing.railWidth
                    - (sizing.sidebarVisible ? alignedSidebarWidth : 0)
                    - (sizing.rightVisible ? alignedRightWidth : 0)
            )

            HStack(spacing: 0) {
                if sizing.sidebarVisible {
                    sidebar()
                        .frame(width: CGFloat(alignedSidebarWidth))
                        .frame(maxHeight: .infinity)
                    DragHandle(
                        axis: .horizontal,
                        onDragChanged: { translation in
                            // Anchor on the rendered width at drag start so
                            // the divider tracks the cursor even when sizing
                            // compressed the pane below its preferred width.
                            let start = sidebarDragStartWidth ?? sizing.sidebarWidth
                            sidebarDragStartWidth = start
                            transientSidebarWidth = PaneDragMath.resolvedWidth(
                                startWidth: start,
                                translation: Double(translation),
                                min: sidebarMin,
                                max: sidebarMax
                            )
                        },
                        onDragEnded: {
                            if let width = transientSidebarWidth {
                                sidebarWidth = width
                                onWidthsChanged()
                            }
                            transientSidebarWidth = nil
                            sidebarDragStartWidth = nil
                        }
                    )
                }
                center(sizing.rightVisible)
                    .frame(width: CGFloat(alignedCenterWidth))
                    .frame(maxHeight: .infinity)
                if sizing.rightVisible {
                    DragHandle(
                        axis: .horizontal,
                        onDragChanged: { translation in
                            let start = rightDragStartWidth ?? sizing.rightWidth
                            rightDragStartWidth = start
                            // Dragging this gutter right shrinks the right
                            // pane, hence the negated translation.
                            transientRightWidth = PaneDragMath.resolvedWidth(
                                startWidth: start,
                                translation: -Double(translation),
                                min: rightMin,
                                max: rightMax
                            )
                        },
                        onDragEnded: {
                            if let width = transientRightWidth {
                                rightWidth = width
                                onWidthsChanged()
                            }
                            transientRightWidth = nil
                            rightDragStartWidth = nil
                        }
                    )
                    right(false)
                        .frame(width: CGFloat(alignedRightWidth))
                        .frame(maxHeight: .infinity)
                } else if railSizing.railWidth > 0 {
                    right(true)
                        .frame(width: CGFloat(railSizing.railWidth))
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
    }
}
