import Foundation

/// The `gg ls --all --json` envelope is a directory, not a current-stack snapshot.
/// Its commits include unpublished entries, but do not carry forge review mapping.
public struct GGStackDirectorySnapshot: Decodable, Sendable {
    public let version: Int
    public let stacks: [GGStackDirectoryEntry]

    public static func decode(fromJSON data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let result: Self
        do { result = try decoder.decode(Self.self, from: data) }
        catch { throw GGServiceError.malformedOutput("GG returned an unreadable stack directory.") }
        guard result.version == 1 else { throw GGServiceError.unsupportedSchema(result.version) }
        guard result.stacks.count <= 500, Set(result.stacks.map(\.name)).count == result.stacks.count else {
            throw GGServiceError.malformedOutput("GG returned an oversized or ambiguous stack directory.")
        }
        return result
    }
}

public struct GGStackDirectoryEntry: Decodable, Sendable {
    public struct Commit: Decodable, Sendable {
        public let position: Int
        public let sha: String
        public let title: String
    }
    public let name: String
    public let base: String
    public let commitCount: Int
    public let commits: [Commit]

    public var hasCompleteShape: Bool {
        !name.isEmpty && !base.isEmpty && commitCount > 0 && commitCount <= 500 && commitCount == commits.count
            && Set(commits.map(\.position)) == Set(1...commitCount)
            && commits.allSatisfy { !$0.sha.isEmpty }
            && Set(commits.map(\.sha)).count == commits.count
    }
}

/// Remote discovery supplies membership only. It cannot establish head, base, or order.
public struct GGRemoteStackDirectorySnapshot: Decodable, Sendable {
    public struct Stack: Decodable, Sendable {
        public let name: String
        public let commitCount: Int
        public let prNumbers: [Int]
    }
    public let version: Int
    public let stacks: [Stack]

    public static func decode(fromJSON data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let result: Self
        do { result = try decoder.decode(Self.self, from: data) }
        catch { throw GGServiceError.malformedOutput("GG returned unreadable remote stack membership.") }
        guard result.version == 1 else { throw GGServiceError.unsupportedSchema(result.version) }
        guard result.stacks.count <= 500, Set(result.stacks.map(\.name)).count == result.stacks.count,
              result.stacks.allSatisfy({ !$0.name.isEmpty && $0.prNumbers.count <= 500 && $0.prNumbers.allSatisfy { $0 > 0 } }) else {
            throw GGServiceError.malformedOutput("GG returned oversized or ambiguous remote stack membership.")
        }
        return result
    }
}
