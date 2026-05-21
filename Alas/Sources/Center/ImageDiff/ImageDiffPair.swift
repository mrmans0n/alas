import AppKit

/// Everything `ImageDiffView` needs to render a comparison. `nil` images
/// represent the "missing" side for adds (no `before`) and deletes (no
/// `after`); the side-by-side view shows a placeholder for `nil`.
struct ImageDiffPair {
    let before: NSImage?
    let after: NSImage?
    let oldPath: String?       // non-nil only when `kind == .renamed`
    let kind: ImageDiffPairKind
    let beforeFrameCount: Int  // 0 when `before` is nil; 1 for static; >1 for animated GIFs
    let afterFrameCount: Int   // 0 when `after`  is nil; 1 for static; >1 for animated GIFs
}
