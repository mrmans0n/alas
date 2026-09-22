import AppKit
import Foundation
import Testing
@testable import Alas

@Suite("ACPImageThumbnail")
struct ACPImageThumbnailTests {
    private func writePNG(width: Int, height: Int) throws -> URL {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.blue.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("thumb-\(width)x\(height).png")
        try png.write(to: url)
        return url
    }

    @Test("decodes an inline data: URI instead of treating it as a file path")
    func decodesDataURI() throws {
        let fileURL = try writePNG(width: 20, height: 10)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let result = try #require(ACPImageEncoding.inlineBase64(fileURL: fileURL, maxDimension: 1568))
        let dataURL = try #require(URL(string: "data:\(result.mimeType);base64,\(result.data)"))

        let image = ACPImageThumbnail.loadImage(from: dataURL)

        #expect(image != nil)
    }

    @Test("still loads a regular file URL")
    func loadsFileURL() throws {
        let fileURL = try writePNG(width: 20, height: 10)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let image = ACPImageThumbnail.loadImage(from: fileURL)

        #expect(image != nil)
    }

    @Test("an unparseable data: URI yields no image rather than crashing")
    func malformedDataURIYieldsNil() throws {
        let dataURL = try #require(URL(string: "data:image/png;base64,not-valid-base64!!!"))

        let image = ACPImageThumbnail.loadImage(from: dataURL)

        #expect(image == nil)
    }
}
