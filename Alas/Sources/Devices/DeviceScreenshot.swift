import CoreImage
import Foundation
import IOSurface

/// PNGs of a simulator frame, for the agent's `device_screenshot` and the
/// Devices tab's screenshot button.
enum DeviceScreenshot {
    private static let context = CIContext()

    /// The frame as PNG, scaled down so its long edge is at most `maxLongEdge`
    /// (nil keeps full size), with the encoded size in pixels.
    static func png(_ surface: IOSurface, maxLongEdge: CGFloat?) -> (data: Data, width: Int, height: Int)? {
        let image = CIImage(ioSurface: surface)
        let longEdge = max(image.extent.width, image.extent.height)
        let scale = maxLongEdge.map { min(1, $0 / longEdge) } ?? 1
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let bounds = scaled.extent.integral
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let data = context.pngRepresentation(of: scaled.cropped(to: bounds), format: .RGBA8, colorSpace: colorSpace)
        else { return nil }
        return (data, Int(bounds.width), Int(bounds.height))
    }

    /// Saves a full-size PNG to the Desktop under Simulator.app's file name
    /// pattern, and returns the file.
    static func saveToDesktop(_ surface: IOSurface, deviceName: String, now: Date = .now) throws -> URL {
        guard let png = png(surface, maxLongEdge: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let safeName = deviceName.replacingOccurrences(of: "/", with: "-")
        let desktop = try FileManager.default.url(for: .desktopDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let file = desktop.appendingPathComponent("Simulator Screenshot - \(safeName) - \(formatter.string(from: now)).png")
        try png.data.write(to: file, options: .withoutOverwriting)
        return file
    }
}
