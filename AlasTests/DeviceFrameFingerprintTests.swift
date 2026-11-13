import CoreVideo
import IOSurface
import Testing
@testable import Alas

struct DeviceFrameFingerprintTests {
    /// A 256×512 BGRA frame filled with 100, with the rows from `from` to `to` (fractions of the height) and the
    /// columns from 0 to `width` (a fraction of the width) set to 255.
    private func frame(paint from: Double = 0, to: Double = 0, width: Double = 1) throws -> IOSurface {
        let surface = try #require(IOSurface(properties: [
            .width: 256, .height: 512, .bytesPerElement: 4, .pixelFormat: kCVPixelFormatType_32BGRA,
        ]))
        surface.lock(options: [], seed: nil)
        defer { surface.unlock(options: [], seed: nil) }
        let bytes = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        let rowBytes = surface.bytesPerRow
        for y in 0..<512 {
            for x in 0..<rowBytes {
                let painted = Double(y) >= from * 512 && Double(y) < to * 512 && Double(x) < width * Double(rowBytes)
                bytes[y * rowBytes + x] = painted ? 255 : 100
            }
        }
        return surface
    }

    @Test(arguments: [
        // A caret: a sliver of a few rows and columns.
        (0.5, 0.51, 0.01, true),
        // A quarter of the screen.
        (0.0, 0.25, 1.0, false),
        // Nothing.
        (0.0, 0.0, 1.0, true),
    ])
    func smallChangesStillMatch(from: Double, to: Double, width: Double, matches: Bool) throws {
        let base = try #require(DeviceFrameFingerprint(try frame()))
        let other = try #require(DeviceFrameFingerprint(try frame(paint: from, to: to, width: width)))
        #expect(base.matches(other) == matches)
    }
}
