import Foundation

public enum CheckpointCaptureError: Error, Equatable, Sendable {
    case unstableWorktree
    case missingSelectedPath(String)
}
