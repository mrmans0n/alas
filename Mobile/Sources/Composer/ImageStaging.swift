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
        for item in items { await stage(try? await item.loadTransferable(type: Data.self), into: session) }
    }

    /// Transcodes and stages one image (a pick or a paste); nil or unreadable data is reported.
    @MainActor
    static func stage(_ raw: Data?, into session: TranscriptSession) async {
        guard let raw, let encoded = await encode(raw) else {
            session.rejection = "That image couldn't be read."
            return
        }
        if let refusal = RemoteAttachmentLimits.refusal(adding: encoded.jpeg.count,
                                                        to: session.draft.images.map(\.data.count)) {
            session.rejection = refusal
            return
        }
        session.draft.images.append(StagedImage(id: UUID(), data: encoded.jpeg, mimeType: "image/jpeg",
                                                thumbnail: encoded.thumbnail))
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

/// The system camera, for a photo to attach; hands back its JPEG, or nothing when cancelled.
struct CameraPicker: UIViewControllerRepresentable {
    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    let take: (Data?) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            // Full quality: staging downscales and re-encodes it like a library pick.
            parent.take((info[.originalImage] as? UIImage)?.jpegData(compressionQuality: 1))
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
