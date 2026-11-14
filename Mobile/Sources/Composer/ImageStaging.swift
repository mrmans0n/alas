import AlasRemoteKit
import ImageIO
import PhotosUI
import SwiftUI

/// Turns library picks into the JPEGs a prompt carries.
enum ImageStaging {
    static let maxSide: CGFloat = 2048
    private static let thumbSide: CGFloat = 160

    /// Loads, transcodes and stages each pick, skipping any it cannot read or that the limits refuse.
    @MainActor
    static func stage(_ items: [PhotosPickerItem], into session: TranscriptSession) async {
        for item in items {
            guard let raw = try? await item.loadTransferable(type: Data.self),
                  let encoded = await encode(raw) else {
                session.rejection = "That photo couldn't be read."
                continue
            }
            if let refusal = RemoteAttachmentLimits.refusal(adding: encoded.jpeg.count,
                                                            to: session.draft.images.map(\.data.count)) {
                session.rejection = refusal
                continue
            }
            session.draft.images.append(StagedImage(id: UUID(), data: encoded.jpeg, mimeType: "image/jpeg",
                                                    thumbnail: encoded.thumbnail))
        }
    }

    /// ImageIO decodes straight to the downscaled size, so a 48 MP photo is never held at full
    /// size. HEIC and other formats come out as JPEG; transparency is flattened onto white.
    @concurrent
    private nonisolated static func encode(_ data: Data) async -> (jpeg: Data, thumbnail: UIImage)? {
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let full = flatten(UIImage(cgImage: cgImage), longestSide: maxSide)
        guard let jpeg = full.jpegData(compressionQuality: 0.8) else { return nil }
        return (jpeg, flatten(full, longestSide: thumbSide))
    }

    private nonisolated static func flatten(_ image: UIImage, longestSide: CGFloat) -> UIImage {
        let scale = min(1, longestSide / max(image.size.width, image.size.height))
        let size = CGSize(width: max(1, (image.size.width * scale).rounded()), height: max(1, (image.size.height * scale).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
