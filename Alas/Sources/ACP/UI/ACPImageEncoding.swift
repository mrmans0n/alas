import AppKit
import Foundation

/// Produces the inline base64 payload Alas sends for an image when the agent
/// advertises image capability. Large images are downscaled to a max
/// dimension (keeping aspect ratio) and re-encoded as PNG to keep the
/// JSON-RPC payload sane. Returns `nil` if the file can't be read/decoded.
enum ACPImageEncoding {
    static func inlineBase64(fileURL: URL, maxDimension: CGFloat) -> (data: String, mimeType: String)? {
        guard let raw = try? Data(contentsOf: fileURL),
              let rep = NSBitmapImageRep(data: raw) else { return nil }

        let w = CGFloat(rep.pixelsWide), h = CGFloat(rep.pixelsHigh)
        guard w > 0, h > 0 else { return nil }

        // Never upscale: clamp the scale at 1. Within-cap images keep their
        // original pixel size; only oversized ones shrink.
        let scale = min(1, maxDimension / max(w, h))

        // Within cap AND we can identify the format → send the original bytes
        // untouched (preserves GIF animation, JPEG quality, etc.). A within-cap
        // image whose MIME we can't sniff falls through and is re-encoded as
        // PNG at its ORIGINAL size (scale == 1), never upscaled.
        if scale >= 1, let mime = ACPImageStaging.sniffMIME(raw) {
            return (raw.base64EncodedString(), mime)
        }

        let target = NSSize(width: floor(w * scale), height: floor(h * scale))
        guard let scaled = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(target.width), pixelsHigh: Int(target.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: scaled)
        NSGraphicsContext.current?.imageInterpolation = .high
        rep.draw(in: NSRect(origin: .zero, size: target))
        NSGraphicsContext.restoreGraphicsState()

        guard let png = scaled.representation(using: .png, properties: [:]) else { return nil }
        return (png.base64EncodedString(), "image/png")
    }
}
