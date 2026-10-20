import CoreGraphics
import Foundation

/// The card's last dock and the size chosen for each dock, kept app-wide.
public struct ACPSideQuestionDockPreferences: Codable, Equatable, Sendable {
    public var dock: ACPSideQuestionDock = .composer
    public var composerHeight: Double = Double(ACPSideQuestionDockLayout.defaultHeight)
    public var topHeight: Double = Double(ACPSideQuestionDockLayout.defaultHeight)
    public var sideWidth: Double = Double(ACPSideQuestionDockLayout.defaultSideWidth)

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case dock, composerHeight, topHeight, sideWidth
    }

    /// Field by field, so one bad value (say, a dock from a newer build)
    /// doesn't throw away the sizes beside it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        dock = (try? c.decodeIfPresent(ACPSideQuestionDock.self, forKey: .dock)) ?? defaults.dock
        composerHeight = (try? c.decodeIfPresent(Double.self, forKey: .composerHeight)) ?? defaults.composerHeight
        topHeight = (try? c.decodeIfPresent(Double.self, forKey: .topHeight)) ?? defaults.topHeight
        sideWidth = (try? c.decodeIfPresent(Double.self, forKey: .sideWidth)) ?? defaults.sideWidth
    }
}
