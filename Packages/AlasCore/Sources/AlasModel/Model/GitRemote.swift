import Foundation
import AlasFoundation

public struct GitRemote: Equatable, Sendable {
    public enum Direction: Equatable, Sendable {
        case fetch
        case push
    }

    public let name: String
    public let url: String
    public let direction: Direction

    public init(name: String, url: String, direction: Direction = .fetch) {
        self.name = name
        self.url = url
        self.direction = direction
    }
}
