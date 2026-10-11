import AppKit

extension NSImage: DiffImage {}

extension ImageDiffSide {
    var image: NSImage? {
        guard case .image(let image, _) = self else { return nil }
        return image as? NSImage
    }
}

extension ImageDiffPair {
    var beforeImage: NSImage? { before.image }
    var afterImage: NSImage? { after.image }

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
