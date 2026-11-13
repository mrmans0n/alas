import CoreImage
import Foundation
import IOSurface

/// PNGs of a simulator frame, for the agent's `device_screenshot` and the
/// Devices tab's screenshot button, and the Desktop files of that button and
/// the record button.
enum DeviceScreenshot {
    private static let context = CIContext()

    /// The frame as an upright PNG, scaled down so its long edge is at most
    /// `maxLongEdge` (nil keeps full size), with the encoded size in pixels.
    static func png(_ frame: DeviceFrame, maxLongEdge: CGFloat?) -> (data: Data, width: Int, height: Int)? {
        let panel = CIImage(ioSurface: frame.surface)
        let turned: CIImage = switch frame.orientation.clockwiseQuarterTurns {
        case 1: panel.oriented(.right)
        case 2: panel.oriented(.down)
        case 3: panel.oriented(.left)
        default: panel
        }
        let image = turned.transformed(by: CGAffineTransform(translationX: -turned.extent.minX, y: -turned.extent.minY))
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
    static func saveToDesktop(_ frame: DeviceFrame, deviceName: String, now: Date = .now) throws -> URL {
        guard let png = png(frame, maxLongEdge: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let file = try desktopFile("Simulator Screenshot", deviceName: deviceName, extension: "png", now: now)
        try png.data.write(to: file, options: .withoutOverwriting)
        return file
    }

    /// Moves a finished screen recording to the Desktop, named like screenshots.
    static func moveRecordingToDesktop(_ recording: URL, deviceName: String, now: Date = .now) throws -> URL {
        let file = try desktopFile("Simulator Recording", deviceName: deviceName, extension: "mov", now: now)
        try FileManager.default.moveItem(at: recording, to: file)
        return file
    }

    private static func desktopFile(_ kind: String, deviceName: String, extension ext: String, now: Date) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let safeName = deviceName.replacingOccurrences(of: "/", with: "-")
        let desktop = try FileManager.default.url(for: .desktopDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        return availableFile(in: desktop, named: "\(kind) - \(safeName) - \(formatter.string(from: now))", extension: ext)
    }

    /// `name.ext` in `directory`, or `name 2.ext`, `name 3.ext`… when taken,
    /// as Finder numbers copies.
    static func availableFile(in directory: URL, named name: String, extension ext: String) -> URL {
        var file = directory.appendingPathComponent("\(name).\(ext)")
        var number = 2
        while FileManager.default.fileExists(atPath: file.path) {
            file = directory.appendingPathComponent("\(name) \(number).\(ext)")
            number += 1
        }
        return file
    }
}
