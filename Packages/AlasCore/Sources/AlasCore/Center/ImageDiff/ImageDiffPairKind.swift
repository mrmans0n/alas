import Foundation

public enum ImageDiffPairKind: CaseIterable, Hashable, Sendable {
    case added       // new image; no `before`
    case deleted     // removed image; no `after`
    case modified    // both sides exist, same path
    case renamed     // both sides exist, paths differ
    case copied      // both sides exist, source path differs
}
