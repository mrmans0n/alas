import Foundation

enum GGStackLoadState: Equatable {
    case inactive
    case loading
    case empty
    case loaded
    case failed(String)

    var hasLoadedCommit: Bool { self == .loaded }
}
