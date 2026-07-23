import CoreGraphics

enum ACPChatLayout {
    static let defaultContentMaxWidth: CGFloat = 720
    static let wideContentMaxWidth: CGFloat = 960
    static func contentMaxWidth(forChatColumnWidth columnWidth: CGFloat) -> CGFloat {
        let growthStartPaneWidth: CGFloat = 1_080
        guard columnWidth > growthStartPaneWidth else {
            return defaultContentMaxWidth
        }

        let extraWidth = columnWidth - growthStartPaneWidth
        return min(wideContentMaxWidth, defaultContentMaxWidth + extraWidth)
    }

    static func contentMaxWidth(forPaneWidth paneWidth: CGFloat) -> CGFloat {
        contentMaxWidth(forChatColumnWidth: paneWidth)
    }
}
