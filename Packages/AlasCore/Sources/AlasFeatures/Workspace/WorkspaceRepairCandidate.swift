import Foundation

public struct WorkspaceRepairCandidate: Equatable, Identifiable, Sendable {
    public var id: String { path }
    public var path: String
    public var lineageID: String
    public var isExactMatch: Bool

    public init(path: String, lineageID: String, isExactMatch: Bool) {
        self.path = path
        self.lineageID = lineageID
        self.isExactMatch = isExactMatch
    }
}
