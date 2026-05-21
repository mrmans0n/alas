import Testing
import Foundation
import AppKit
import CoreGraphics
@testable import Alas

struct ImageDiffDifferenceComputerTests {
    /// Build a solid-color `NSImage` of the given pixel size via direct
    /// CGImage construction. Avoids `NSBitmapImageRep`, which produces
    /// undifferentiated bytes for different colors in the test host.
    private func solid(red: UInt8, green: UInt8, blue: UInt8, w: Int, h: Int) -> NSImage {
        let bytesPerPixel = 4
        let bytesPerRow = w * bytesPerPixel
        var bytes = [UInt8](repeating: 0, count: h * bytesPerRow)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            bytes[i] = red
            bytes[i + 1] = green
            bytes[i + 2] = blue
            bytes[i + 3] = 255
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let cg = CGImage(
            width: w, height: h,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue:
                CGImageAlphaInfo.premultipliedLast.rawValue |
                CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        return NSImage(cgImage: cg, size: NSSize(width: w, height: h))
    }

    @Test func identicalInputsHaveZeroChangedPixels() {
        let a = solid(red: 255, green: 0, blue: 0, w: 10, h: 10)
        let b = solid(red: 255, green: 0, blue: 0, w: 10, h: 10)
        let result = ImageDiffDifferenceComputer.compute(before: a, after: b)
        #expect(result.totalPixels == 100)
        #expect(result.changedPixelCount == 0)
    }

    @Test func completelyDifferentInputsHaveAllChanged() {
        let a = solid(red: 255, green: 0, blue: 0, w: 10, h: 10)
        let b = solid(red: 0, green: 0, blue: 255, w: 10, h: 10)
        let result = ImageDiffDifferenceComputer.compute(before: a, after: b)
        #expect(result.totalPixels == 100)
        #expect(result.changedPixelCount == 100)
    }

    @Test func mismatchedDimensionsCountOutsideOverlapAsChanged() {
        // before is 10x10, after is 20x20. Canvas is union = 20x20 = 400.
        // The overlap (top-left 10x10) is identical → 0 changed there.
        // The non-overlap region = 400 - 100 = 300 → all changed.
        let a = solid(red: 255, green: 0, blue: 0, w: 10, h: 10)
        let b = solid(red: 255, green: 0, blue: 0, w: 20, h: 20)
        let result = ImageDiffDifferenceComputer.compute(before: a, after: b)
        #expect(result.totalPixels == 400)
        #expect(result.changedPixelCount == 300)
    }

    @Test func maskIsNotNil() {
        let a = solid(red: 255, green: 0, blue: 0, w: 4, h: 4)
        let b = solid(red: 0, green: 0, blue: 255, w: 4, h: 4)
        let result = ImageDiffDifferenceComputer.compute(before: a, after: b)
        #expect(result.mask != nil)
    }
}
