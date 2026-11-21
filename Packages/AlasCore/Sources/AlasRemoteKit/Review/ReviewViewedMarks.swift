import Foundation

/// Files the reviewer ticked as viewed. A mark holds the diff's hash, so it lapses when the diff changes.
public struct ReviewViewedMarks: Equatable, Sendable {
    public private(set) var stored: [String: String]

    /// `stored` maps an entry key to the diff hash it was marked at.
    public init(stored: [String: String] = [:]) {
        self.stored = stored
    }

    public static func hash(of hunks: [RemoteDiffHunk]) -> String {
        hunks.map(\.linesHash).joined(separator: ",")
    }

    private static func key(_ id: ReviewEntryID) -> String {
        id.namespace + "\u{1F}" + id.path
    }

    public func isViewed(_ id: ReviewEntryID, hunks: [RemoteDiffHunk]) -> Bool {
        stored[Self.key(id)] == Self.hash(of: hunks)
    }

    public mutating func mark(_ id: ReviewEntryID, hunks: [RemoteDiffHunk]) {
        stored[Self.key(id)] = Self.hash(of: hunks)
    }

    public mutating func unmark(_ id: ReviewEntryID) {
        stored[Self.key(id)] = nil
    }
}
