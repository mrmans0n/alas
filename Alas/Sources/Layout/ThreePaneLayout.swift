import SwiftUI

struct ThreePaneLayout<Sidebar: View, Center: View, Right: View>: View {
    @Binding var sidebarWidth: Double
    @Binding var rightWidth: Double
    let rightVisible: Bool
    let onWidthsChanged: () -> Void
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let center: () -> Center
    @ViewBuilder let right: () -> Right

    private let sidebarMin: Double = 200
    private let sidebarMax: Double = 420
    private let rightMin: Double = 240
    private let rightMax: Double = 560

    var body: some View {
        HStack(spacing: 0) {
            sidebar()
                .frame(width: CGFloat(sidebarWidth))
                .frame(maxHeight: .infinity)
            DragHandle(axis: .horizontal) { delta in
                sidebarWidth = DragHandle.clamp(
                    value: sidebarWidth + Double(delta),
                    min: sidebarMin, max: sidebarMax
                )
                onWidthsChanged()
            }
            center()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if rightVisible {
                DragHandle(axis: .horizontal) { delta in
                    rightWidth = DragHandle.clamp(
                        value: rightWidth - Double(delta),
                        min: rightMin, max: rightMax
                    )
                    onWidthsChanged()
                }
                right()
                    .frame(width: CGFloat(rightWidth))
                    .frame(maxHeight: .infinity)
            }
        }
    }
}
