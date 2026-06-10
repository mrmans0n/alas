import CoreGraphics

enum ACPChatLayout {
    static let defaultContentMaxWidth: CGFloat = 720
    static let wideContentMaxWidth: CGFloat = 960

    static func contentMaxWidth(forPaneWidth paneWidth: CGFloat) -> CGFloat {
        let growthStartPaneWidth: CGFloat = 1_080
        guard paneWidth > growthStartPaneWidth else {
            return defaultContentMaxWidth
        }

        let extraWidth = paneWidth - growthStartPaneWidth
        return min(wideContentMaxWidth, defaultContentMaxWidth + extraWidth)
    }
}
