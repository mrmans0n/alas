import AppKit
import Foundation
import Testing
@testable import Alas

@Suite("ACPImageEncoding")
struct ACPImageEncodingTests {
    /// Write a solid-color PNG of EXACTLY the given pixel size to a temp file.
    /// Builds the bitmap rep directly (not via `NSImage.lockFocus`, which
    /// rasterizes at the display's backing scale and would yield 2× pixels on
    /// a Retina screen — making the dimension assertions flaky).
    private func writePNG(width: Int, height: Int) throws -> URL {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("enc-\(width)x\(height).png")
        try png.write(to: url)
        return url
    }

    @Test("downscales an oversized image below the cap and returns base64")
    func downscalesLarge() throws {
        let url = try writePNG(width: 4000, height: 2000)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try #require(ACPImageEncoding.inlineBase64(fileURL: url, maxDimension: 1568))
        #expect(result.mimeType == "image/png")
        let decoded = try #require(Data(base64Encoded: result.data))
        let rep = try #require(NSBitmapImageRep(data: decoded))
        #expect(rep.pixelsWide <= 1568)
        #expect(rep.pixelsHigh <= 1568)
    }

    @Test("leaves a small image at its original dimensions")
    func keepsSmall() throws {
        let url = try writePNG(width: 100, height: 80)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try #require(ACPImageEncoding.inlineBase64(fileURL: url, maxDimension: 1568))
        let decoded = try #require(Data(base64Encoded: result.data))
        let rep = try #require(NSBitmapImageRep(data: decoded))
        #expect(rep.pixelsWide == 100)
        #expect(rep.pixelsHigh == 80)
    }
}
