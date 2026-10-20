import Foundation
import AlasFoundation

public enum GGWorktreeMode: String, Codable, Equatable, CaseIterable, Sendable {
    case inherit
    case on
    case off
}
