import SwiftUI

/// Standard image-editor checkerboard. Two grays; tile size is fixed in
/// view-space pixels (not image-space) so it always reads the same
/// regardless of the underlying image's resolution.
struct ImageCheckerboardBackground: View {
    var tile: CGFloat = 8

    var body: some View {
        Canvas { ctx, size in
            let cols = Int(ceil(size.width / tile))
            let rows = Int(ceil(size.height / tile))
            for r in 0..<rows {
                for c in 0..<cols {
                    let isDark = (r + c) % 2 == 0
                    let rect = CGRect(
                        x: CGFloat(c) * tile,
                        y: CGFloat(r) * tile,
                        width: tile, height: tile
                    )
                    ctx.fill(
                        Path(rect),
                        with: .color(isDark ? .gray.opacity(0.18) : .gray.opacity(0.08))
                    )
                }
            }
        }
    }
}
