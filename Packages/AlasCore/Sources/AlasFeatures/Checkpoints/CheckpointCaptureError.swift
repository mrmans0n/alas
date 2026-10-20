import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform

public enum CheckpointCaptureError: Error, Equatable, Sendable {
    case unstableWorktree
    case missingSelectedPath(String)
}
