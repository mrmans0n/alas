import Foundation
import AlasACP

/// A `computer_*` request from the CLI/MCP bridge. Bounds mirror the Rust side.
public struct ComputerUseCommand: Equatable, Sendable {
    public enum Action: String, CaseIterable, Sendable { case apps, screenshot, inspect }

    public var action: Action
    public var windowID: UInt32?
    public var query: String?
    public var limit: Int
    public var maxDepth: Int

    public init(action: Action, windowID: UInt32? = nil, query: String? = nil, limit: Int = 300, maxDepth: Int = 12) {
        self.action = action
        self.windowID = windowID
        self.query = query
        self.limit = limit
        self.maxDepth = maxDepth
    }

    private struct Params: Decodable {
        var window_id: UInt32?
        var query: String?
        var limit: Int?
        var max_depth: Int?
    }

    public static func decode(action: Action, data: Data) throws -> Self {
        let params = try AlasCLIRequest.decodeParamsIfPresent(Params.self, from: data)
        let command = Self(
            action: action, windowID: params?.window_id, query: params?.query,
            limit: params?.limit ?? 300, maxDepth: params?.max_depth ?? 12
        )
        try command.validate()
        return command
    }

    public func validate() throws {
        func require(_ condition: Bool) throws {
            guard condition else { throw AlasCLIRequestError.malformed }
        }
        switch action {
        case .apps:
            try require(windowID == nil && query == nil)
        case .screenshot:
            try require(windowID != nil && query == nil)
        case .inspect:
            try require(windowID != nil)
            if let query {
                try require(!query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && query.utf8.count <= 256)
            }
            try require((1...3000).contains(limit) && (1...12).contains(maxDepth))
        }
    }
}
