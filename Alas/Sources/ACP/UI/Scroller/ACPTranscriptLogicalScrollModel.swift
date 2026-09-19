import CoreGraphics

/// Maps a variable-height transcript onto a stable, message-index-based
/// scrollbar range. Render-window membership and measured row heights are
/// intentionally absent from this model, so paging cannot resize the thumb.
enum ACPTranscriptLogicalScrollModel {
    static let logicalPointsPerMessage: CGFloat = 96

    struct Metrics: Equatable {
        let value: Double
        let knobProportion: CGFloat
        let logicalViewportMessages: CGFloat
    }

    /// `topGlobalIndex` is fractional so a viewport whose top sits part-way
    /// through a folded tool-call group's on-screen height (which represents
    /// several messages) advances the thumb smoothly across that height
    /// instead of holding it fixed at the group's first member and then
    /// jumping by the remaining member count at the next row.
    static func metrics(
        totalCount: Int,
        viewportHeight: CGFloat,
        topGlobalIndex: CGFloat,
        isAtTail: Bool
    ) -> Metrics {
        let count = max(0, totalCount)
        let viewportMessages = logicalViewportMessages(viewportHeight: viewportHeight)
        let knobProportion = count == 0 ? 1 : min(1, viewportMessages / CGFloat(count))
        let maximumTopIndex = max(0, CGFloat(count) - viewportMessages)
        let value: Double
        if maximumTopIndex == 0 {
            value = 0
        } else if isAtTail {
            value = 1
        } else {
            value = Double(min(max(topGlobalIndex, 0), maximumTopIndex) / maximumTopIndex)
        }
        return Metrics(
            value: value,
            knobProportion: knobProportion,
            logicalViewportMessages: viewportMessages
        )
    }

    static func targetGlobalIndex(
        value: Double,
        totalCount: Int,
        viewportHeight: CGFloat
    ) -> Int {
        let count = max(0, totalCount)
        let viewportMessages = logicalViewportMessages(viewportHeight: viewportHeight)
        let maximumTopIndex = max(0, CGFloat(count) - viewportMessages)
        let clampedValue = min(max(value, 0), 1)
        return Int((CGFloat(clampedValue) * maximumTopIndex).rounded())
    }

    private static func logicalViewportMessages(viewportHeight: CGFloat) -> CGFloat {
        max(1, max(0, viewportHeight) / logicalPointsPerMessage)
    }
}
