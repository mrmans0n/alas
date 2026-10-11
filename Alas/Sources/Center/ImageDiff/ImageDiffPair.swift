import Foundation

/// A decoded image owned by the platform layer (an `NSImage` in the app).
protocol DiffImage: AnyObject, Sendable {}

struct ImageDiffLoadFailure: Equatable, Sendable {
    let message: String
}

enum ImageDiffSide {
    case image(any DiffImage, frameCount: Int)
    case missing
    case failed(ImageDiffLoadFailure)

    var frameCount: Int {
        guard case .image(_, let frameCount) = self else { return 0 }
        return frameCount
    }

    var isLoadedImage: Bool {
        if case .image = self { return true }
        return false
    }
}

/// Everything `ImageDiffView` needs to render a comparison.
struct ImageDiffPair {
    let before: ImageDiffSide
    let after: ImageDiffSide
    let oldPath: String?
    let kind: ImageDiffPairKind

    var beforeFrameCount: Int { before.frameCount }
    var afterFrameCount: Int { after.frameCount }
    var hasFailure: Bool {
        if case .failed = before { return true }
        if case .failed = after { return true }
        return false
    }

    static func failedLoading() -> ImageDiffPair {
        let failure = ImageDiffLoadFailure(message: "Image diff could not be loaded.")
        return ImageDiffPair(
            before: .failed(failure),
            after: .failed(failure),
            oldPath: nil,
            kind: .modified
        )
    }

    init(
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
