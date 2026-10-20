import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform

/// A decoded image owned by the platform layer (an `NSImage` in the app).
public protocol DiffImage: AnyObject, Sendable {}

public struct ImageDiffLoadFailure: Equatable, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

public enum ImageDiffSide: Sendable {
    case image(any DiffImage, frameCount: Int)
    case missing
    case failed(ImageDiffLoadFailure)

    public var frameCount: Int {
        guard case .image(_, let frameCount) = self else { return 0 }
        return frameCount
    }

    public var isLoadedImage: Bool {
        if case .image = self { return true }
        return false
    }
}

/// Everything `ImageDiffView` needs to render a comparison.
public struct ImageDiffPair: Sendable {
    public let before: ImageDiffSide
    public let after: ImageDiffSide
    public let oldPath: String?
    public let kind: ImageDiffPairKind

    public var beforeFrameCount: Int { before.frameCount }
    public var afterFrameCount: Int { after.frameCount }
    public var hasFailure: Bool {
        if case .failed = before { return true }
        if case .failed = after { return true }
        return false
    }

    public static func failedLoading() -> ImageDiffPair {
        let failure = ImageDiffLoadFailure(message: "Image diff could not be loaded.")
        return ImageDiffPair(
            before: .failed(failure),
            after: .failed(failure),
            oldPath: nil,
            kind: .modified
        )
    }

    public init(
        before: ImageDiffSide,
        after: ImageDiffSide,
        oldPath: String?,
        kind: ImageDiffPairKind
    ) {
        self.before = before
        self.after = after
        self.oldPath = oldPath
        self.kind = kind
    }
}
