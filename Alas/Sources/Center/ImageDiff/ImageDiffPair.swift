import AppKit

struct ImageDiffLoadFailure: Equatable, Sendable {
    let message: String
}

enum ImageDiffSide {
    case image(NSImage, frameCount: Int)
    case missing
    case failed(ImageDiffLoadFailure)

    var image: NSImage? {
        guard case .image(let image, _) = self else { return nil }
        return image
    }

    var frameCount: Int {
        guard case .image(_, let frameCount) = self else { return 0 }
        return frameCount
    }

    var isLoadedImage: Bool {
        image != nil
    }
}

/// Everything `ImageDiffView` needs to render a comparison.
struct ImageDiffPair {
    let before: ImageDiffSide
    let after: ImageDiffSide
    let oldPath: String?
    let kind: ImageDiffPairKind

    var beforeImage: NSImage? { before.image }
    var afterImage: NSImage? { after.image }
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

    init(
        before: NSImage?,
        after: NSImage?,
        oldPath: String?,
        kind: ImageDiffPairKind,
        beforeFrameCount: Int,
        afterFrameCount: Int
    ) {
        self.init(
            before: before.map { .image($0, frameCount: beforeFrameCount) } ?? .missing,
            after: after.map { .image($0, frameCount: afterFrameCount) } ?? .missing,
            oldPath: oldPath,
            kind: kind
        )
    }
}
