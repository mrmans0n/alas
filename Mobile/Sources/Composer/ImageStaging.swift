import AlasRemoteKit
import PhotosUI
import SwiftUI

/// Turns library picks into the JPEGs a prompt carries.
enum ImageStaging {
    static let maxSide: CGFloat = 2048
    private static let thumbSide: CGFloat = 160

    /// Loads, transcodes and stages each pick, stopping at the first refusal.
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
                return
            }
            session.draft.images.append(StagedImage(id: UUID(), data: encoded.jpeg, mimeType: "image/jpeg",
                                                    thumbnail: encoded.thumbnail))
        }
    }

    /// Decodes any format UIKit reads (HEIC included), downscales to `maxSide` and re-encodes.
    @concurrent
    private nonisolated static func encode(_ data: Data) async -> (jpeg: Data, thumbnail: UIImage)? {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        let full = render(image, longestSide: maxSide)
        guard let jpeg = full.jpegData(compressionQuality: 0.8) else { return nil }
        return (jpeg, render(full, longestSide: thumbSide))
    }

    private nonisolated static func render(_ image: UIImage, longestSide: CGFloat) -> UIImage {
        let scale = min(1, longestSide / max(image.size.width, image.size.height))
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
