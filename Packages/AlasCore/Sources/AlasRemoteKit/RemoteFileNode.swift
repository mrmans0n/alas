import Foundation

/// Wire projection of `FileTreeNode`. `kind` is "dir" or "file";
/// `childrenState` carries `DirectoryChildrenState`'s raw value.
public struct RemoteFileNode: Codable, Equatable, Sendable {
    public let name: String
    public let path: String
    public let kind: String
    public let badge: String?
    public let childrenState: String
    public let isSubmodule: Bool

    public init(name: String, path: String, kind: String, badge: String?, childrenState: String, isSubmodule: Bool) {
        self.name = name
        self.path = path
        self.kind = kind
        self.badge = badge
        self.childrenState = childrenState
        self.isSubmodule = isSubmodule
    }
}
