import Foundation

enum ImageDiffMode: String, CaseIterable, Hashable {
    case sideBySide
    case overlay
    case swipe
    case difference

    /// Side-by-side works for one-sided diffs (we just show a placeholder
    /// on the missing side). The other three modes need both blobs to
    /// produce something meaningful, so they're disabled for adds/deletes.
    func isApplicable(for kind: ImageDiffPairKind) -> Bool {
        switch self {
        case .sideBySide: return true
        case .overlay, .swipe, .difference:
            switch kind {
            case .added, .deleted: return false
            case .modified, .renamed: return true
            }
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
