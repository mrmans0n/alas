import Foundation

public enum GGStackLoadState: Equatable, Sendable {
    case inactive
    case loading
    case empty
    case loaded
    case failed(String)

    public var hasLoadedCommit: Bool { self == .loaded }
}
