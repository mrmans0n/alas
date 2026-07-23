import Foundation

enum ImageDiffMode: String, CaseIterable, Hashable {
    case sideBySide
    case overlay
    case swipe
    case difference

    /// Side-by-side works for one-sided or failed diffs. The other three
    /// modes require loaded images on both sides.
    func isApplicable(for pair: ImageDiffPair) -> Bool {
        switch self {
        case .sideBySide:
            return true
        case .overlay, .swipe, .difference:
            return pair.before.isLoadedImage && pair.after.isLoadedImage
        }
    }

    var displayName: String {
        switch self {
        case .sideBySide: return "Side by side"
        case .overlay:    return "Overlay"
        case .swipe:      return "Swipe"
        case .difference: return "Difference"
        }
    }

    var systemImageName: String {
        switch self {
        case .sideBySide: return "rectangle.split.2x1"
        case .overlay:    return "square.on.square"
        case .swipe:      return "arrow.left.and.right.square"
        case .difference: return "circle.lefthalf.filled.righthalf.striped.horizontal"
        }
    }
}
