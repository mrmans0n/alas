import SwiftUI

struct ThreePaneLayout<Sidebar: View, Center: View, Right: View>: View {
    @Binding var sidebarWidth: Double
    @Binding var rightWidth: Double
    let sidebarVisible: Bool
    let rightVisible: Bool
    let onWidthsChanged: () -> Void
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let center: () -> Center
    @ViewBuilder let right: () -> Right

    private let sidebarMin: Double = 200
    private let sidebarMax: Double = 420
    private let rightMin: Double = 240
    private let rightMax: Double = 560
    private let centerMin: Double = 400
    private let dividerWidth: Double = 6

    var body: some View {
        GeometryReader { proxy in
            let sizing = ThreePaneSizing.calculate(
                availableWidth: Double(proxy.size.width),
                preferredSidebarWidth: sidebarWidth,
                preferredRightWidth: rightWidth,
                sidebarPreferredVisible: sidebarVisible,
                rightPreferredVisible: rightVisible,
                configuration: ThreePaneSizing.Configuration(
                    sidebarMin: sidebarMin,
                    sidebarMax: sidebarMax,
                    rightMin: rightMin,
                    rightMax: rightMax,
                    centerMin: centerMin,
                    dividerWidth: dividerWidth
                )
            )

            HStack(spacing: 0) {
                if sizing.sidebarVisible {
                    sidebar()
                        .frame(width: CGFloat(sizing.sidebarWidth))
                        .frame(maxHeight: .infinity)
                    DragHandle(axis: .horizontal, onDrag: { delta in
                        sidebarWidth = DragHandle.clamp(
                            value: sidebarWidth + Double(delta),
                            min: sidebarMin, max: sidebarMax
                        )
                    }, onEnded: onWidthsChanged)
                }
                center()
                    .frame(width: CGFloat(sizing.centerWidth))
                    .frame(maxHeight: .infinity)
                if sizing.rightVisible {
                    DragHandle(axis: .horizontal, onDrag: { delta in
                        rightWidth = DragHandle.clamp(
                            value: rightWidth - Double(delta),
                            min: rightMin, max: rightMax
                        )
                    }, onEnded: onWidthsChanged)
                    right()
                        .frame(width: CGFloat(sizing.rightWidth))
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
    }
}
