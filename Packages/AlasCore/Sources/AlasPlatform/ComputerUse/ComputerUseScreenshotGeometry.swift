import Foundation

public enum ComputerUseScreenshotGeometry {
    /// Output pixel size for a window screenshot. Never upscales beyond the
    /// native backing size; `scale` is output pixels per point.
    public static func output(
        pointSize: CGSize,
        backingScale: CGFloat,
        maxLongEdge: CGFloat = 1280
    ) -> (pixelSize: CGSize, scale: CGFloat) {
        let nativeWidth = pointSize.width * backingScale
        let nativeHeight = pointSize.height * backingScale
        let longEdge = max(nativeWidth, nativeHeight)
        var scale = backingScale
        if longEdge > maxLongEdge, longEdge > 0 {
            scale = backingScale * maxLongEdge / longEdge
        }
        let width = max(1, (pointSize.width * scale).rounded(.down))
        let height = max(1, (pointSize.height * scale).rounded(.down))
        return (CGSize(width: width, height: height), scale)
    }
}
