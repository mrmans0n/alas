import Foundation

public enum FrozenBranchIntent: Equatable, Sendable {
    case create(atCommit: String)
    case reuse(atCommit: String)

    public init(_ intent: WorkspaceBranchIntent, baseCommit: String) {
        switch intent {
        case .create(let commit): self = .create(atCommit: commit)
        case .reuse: self = .reuse(atCommit: baseCommit)
        }
    }

    public var commit: String {
        switch self {
        case .create(let atCommit), .reuse(let atCommit): atCommit
        }
    }
}
