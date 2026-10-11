import Foundation

/// What a `right` panel's rail button carries, set with `panel/badge` (API 15): a count, or a dot when `count` is nil.
struct PluginPanelBadge: Equatable, Sendable {
    let count: Int?
    let tone: PluginViewNode.Tone
}
