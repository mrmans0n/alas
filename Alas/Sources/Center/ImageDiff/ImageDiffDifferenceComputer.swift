import AppKit
import CoreImage
import CoreGraphics

/// Pure pixel comparison. Top-left aligned, union-of-dimensions canvas.
/// Pixels in the non-overlap region (outside one input but inside the
/// other) are treated as fully changed.
///
/// The mask is pink (#f472b6) where changed, black elsewhere. Both inputs
/// are decoded to RGBA8 in linear sRGB before comparison; small JPEG codec
/// noise is absorbed by a fixed threshold.
enum ImageDiffDifferenceComputer {
    struct Result {
        let mask: NSImage?
        let totalPixels: Int
        let changedPixelCount: Int
    }

    /// Fixed threshold (0–255). Pixels whose max channel-wise abs diff is
    /// <= this are considered unchanged. Small enough that real edits
    /// register, large enough that JPEG re-encoding doesn't false-positive.
    private static let threshold: UInt8 = 4

    static func compute(before: NSImage, after: NSImage) -> Result {
        guard let cgBefore = cgImage(from: before),
              let cgAfter  = cgImage(from: after) else {
            return Result(mask: nil, totalPixels: 0, changedPixelCount: 0)
        }
        let w = max(cgBefore.width, cgAfter.width)
        let h = max(cgBefore.height, cgAfter.height)
        guard w > 0, h > 0 else {
            return Result(mask: nil, totalPixels: 0, changedPixelCount: 0)
        }

        guard let beforePixels = pixels(of: cgBefore, canvasW: w, canvasH: h),
              let afterPixels  = pixels(of: cgAfter,  canvasW: w, canvasH: h) else {
            return Result(mask: nil, totalPixels: w * h, changedPixelCount: 0)
        }

        let total = w * h
        var mask = [UInt8](repeating: 0, count: total * 4) // RGBA
        var changed = 0
        for i in 0..<total {
            let bIdx = i * 4
            let aR = beforePixels[bIdx + 0], aG = beforePixels[bIdx + 1]
            let aB = beforePixels[bIdx + 2], aA = beforePixels[bIdx + 3]
            let cR = afterPixels[bIdx + 0],  cG = afterPixels[bIdx + 1]
            let cB = afterPixels[bIdx + 2],  cA = afterPixels[bIdx + 3]
            let d = max(
                absDiff(aR, cR),
                absDiff(aG, cG),
                absDiff(aB, cB),
                absDiff(aA, cA)
            )
            if d > threshold {
                changed += 1
                // Pink #f472b6 on opaque black background.
                mask[bIdx + 0] = 0xf4
                mask[bIdx + 1] = 0x72
                mask[bIdx + 2] = 0xb6
                mask[bIdx + 3] = 0xff
            } else {
                mask[bIdx + 3] = 0xff
            }
        }

        return Result(
            mask: maskImage(rgba: mask, width: w, height: h),
            totalPixels: total,
            changedPixelCount: changed
        )
    }

    private static func absDiff(_ a: UInt8, _ b: UInt8) -> UInt8 {
        a > b ? a - b : b - a
    }

    private static func cgImage(from image: NSImage) -> CGImage? {
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// Render `cg` into a fresh canvas of (canvasW × canvasH), top-left
    /// aligned (origin 0,0 in image coordinates = top-left of canvas).
    /// Returns RGBA8 bytes. Region outside `cg`'s extent is left as
    /// transparent-zero (0,0,0,0), which contrasts maximally against any
    /// non-zero pixel and so registers as changed against the other side.
    private static func pixels(of cg: CGImage, canvasW: Int, canvasH: Int) -> [UInt8]? {
        let bytesPerPixel = 4
        let bytesPerRow = canvasW * bytesPerPixel
        var bytes = [UInt8](repeating: 0, count: canvasH * bytesPerRow)

        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let bitmapInfo: UInt32 =
            CGImageAlphaInfo.premultipliedLast.rawValue |
            CGBitmapInfo.byteOrder32Big.rawValue

        var success = false
        bytes.withUnsafeMutableBytes { rawBuf in
            guard let base = rawBuf.baseAddress,
                  let ctx = CGContext(
                    data: base,
                    width: canvasW, height: canvasH,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: space,
                    bitmapInfo: bitmapInfo
                  ) else { return }
            // Top-left alignment in image coordinates means drawing the
            // image starting at (0, canvasH - imgH) in CG's bottom-up
            // coordinate system.
            let drawRect = CGRect(
                x: 0,
                y: canvasH - cg.height,
                width: cg.width,
                height: cg.height
            )
            ctx.draw(cg, in: drawRect)
            success = true
        }
        return success ? bytes : nil
    }

    private static func maskImage(rgba: [UInt8], width: Int, height: Int) -> NSImage? {
        let bytesPerRow = width * 4
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: space,
                bitmapInfo: CGBitmapInfo(rawValue:
                    CGImageAlphaInfo.premultipliedLast.rawValue |
                    CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent
              ) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: width, height: height))
        return img
    }
}
