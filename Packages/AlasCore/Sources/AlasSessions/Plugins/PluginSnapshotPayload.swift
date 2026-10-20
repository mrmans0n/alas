import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

/// `workspace/snapshot` result and `workspace/changed` params.
public struct PluginSnapshotPayload: Codable, Equatable, Sendable {
    public let snapshot: PluginWorkspaceSnapshot

    public init(snapshot: PluginWorkspaceSnapshot) {
        self.snapshot = snapshot
    }
}
