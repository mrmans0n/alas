import Foundation

enum DiffLayoutMode: String, Codable, Equatable, CaseIterable {
    case split
    case stacked

    var title: String {
        switch self {
        case .split: return "Split"
        case .stacked: return "Stacked"
        }
    }
}
