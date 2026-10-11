import Foundation

/// Produces the inline base64 payload Alas sends for an image when the agent
/// advertises image capability. Large images are downscaled to a max
/// dimension (keeping aspect ratio) and re-encoded as PNG to keep the
/// JSON-RPC payload sane. Returns `nil` if the file can't be read/decoded.
///
/// The decoding and re-encoding need AppKit; `PlatformServices.install()`
/// sets `encoder` once at launch, before any reads.
enum ACPImageEncoding {
    nonisolated(unsafe) static var encoder: @Sendable (_ fileURL: URL, _ maxDimension: CGFloat) -> (data: String, mimeType: String)? = { _, _ in nil }

    static func inlineBase64(fileURL: URL, maxDimension: CGFloat) -> (data: String, mimeType: String)? {
        encoder(fileURL, maxDimension)
    }
}
