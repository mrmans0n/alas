import SwiftUI

/// Type-erased Equatable used to decide whether a mounted diff row needs its
/// SwiftUI content rebuilt.
struct AppKitDiffRowEqualityToken {
    private let base: Any
    private let equalsBase: (Any) -> Bool

    init<T: Equatable>(_ value: T) {
        base = value
        equalsBase = { ($0 as? T) == value }
    }

    func isEqual(to other: AppKitDiffRowEqualityToken) -> Bool {
        equalsBase(other.base)
    }
}

enum AppKitDiffRowRetention: Equatable {
    case recyclable
    case pinned
}

struct AppKitDiffRowSpec {
    let id: String
    let ownerID: String?
    let equalityToken: AppKitDiffRowEqualityToken
    let estimatedHeight: CGFloat
    var retention: AppKitDiffRowRetention = .recyclable
    let build: () -> AnyView
}

struct AppKitDiffRowPlan {
    let rows: [AppKitDiffRowSpec]
}

enum AppKitDiffScrollAlignment: Equatable {
    case top
    case center
}

struct AppKitDiffScrollRequest: Equatable {
    let targetID: String
    let fallbackID: String?
    let alignment: AppKitDiffScrollAlignment
    let animated: Bool
    let generation: Int
}

struct AppKitDiffScrollAnchor: Equatable {
    let rowID: String
    let intraRowOffset: CGFloat
}
