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

extension AppKitDiffRowEqualityToken: Equatable {
    static func == (lhs: AppKitDiffRowEqualityToken, rhs: AppKitDiffRowEqualityToken) -> Bool {
        lhs.isEqual(to: rhs)
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
    var contextRowCount: Int? = nil
    let build: () -> AnyView
}

struct AppKitDiffContentInsets: Equatable {
    var top: CGFloat = 0
    var bottom: CGFloat = 0
    var left: CGFloat = 0
    var right: CGFloat = 0

    static let zero = AppKitDiffContentInsets()

    var horizontal: CGFloat { left + right }
}

struct AppKitDiffRowPlan {
    let rows: [AppKitDiffRowSpec]
    var contentInsets: AppKitDiffContentInsets = .zero

    func withContentInsets(_ insets: AppKitDiffContentInsets) -> AppKitDiffRowPlan {
        var copy = self
        copy.contentInsets = insets
        return copy
    }
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
