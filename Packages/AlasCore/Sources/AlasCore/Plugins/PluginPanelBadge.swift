import Foundation

/// What a `right` panel's rail button carries, set with `panel/badge` (API 15): a count, or a dot when `count` is nil.
public struct PluginPanelBadge: Equatable, Sendable {
    public let count: Int?
    public let tone: PluginViewNode.Tone

    public init(count: Int?, tone: PluginViewNode.Tone) {
        self.count = count
        self.tone = tone
    }
}
