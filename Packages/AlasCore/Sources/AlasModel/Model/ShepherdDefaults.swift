import Foundation
import AlasFoundation

/// Global defaults for newly bound PRs (`AppConfig.Changes.shepherd`).
public struct ShepherdDefaults: Codable, Equatable, Sendable {
    public var autoFix: Bool = true
    public var autoMerge: Bool = false
    public var archiveAfterMerge: Bool = false

    private enum CodingKeys: String, CodingKey {
        case autoFix, autoMerge, archiveAfterMerge
    }

    public init(autoFix: Bool = true, autoMerge: Bool = false, archiveAfterMerge: Bool = false) {
        self.autoFix = autoFix
        self.autoMerge = autoMerge
        self.archiveAfterMerge = archiveAfterMerge
    }

    /// Tolerant, like the rest of `AppConfig`: a missing or mistyped key keeps
    /// its default instead of failing the whole config.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        autoFix = (try? c.decode(Bool.self, forKey: .autoFix)) ?? true
        autoMerge = (try? c.decode(Bool.self, forKey: .autoMerge)) ?? false
        archiveAfterMerge = (try? c.decode(Bool.self, forKey: .archiveAfterMerge)) ?? false
    }
}
