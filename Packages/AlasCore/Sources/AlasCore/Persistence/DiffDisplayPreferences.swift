import Foundation

public enum DiffLayoutMode: String, Codable, Equatable, CaseIterable, Sendable {
    case split
    case stacked

    public var title: String {
        switch self {
        case .split: return "Split"
        case .stacked: return "Stacked"
        }
    }
}
