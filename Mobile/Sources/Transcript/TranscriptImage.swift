import AlasRemoteKit
import SwiftUI

/// A markdown or tool-call image: full width, never upscaled, at most 320 pt tall.
/// Until it loads, or when it cannot, it reads as its label.
struct TranscriptImage: View {
    let source: RemoteTranscriptImageSource
    let label: String
    /// A host image's bytes by path, through the session's cached `readTranscriptImage`.
    var image: (String) -> UIImage? = { _ in nil }
    /// Opens the viewer once there is an image; nil leaves it inert.
    var onTap: ((UIImage) -> Void)?

    var body: some View {
        if let loaded {
            Image(uiImage: loaded)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: loaded.size.width, maxHeight: min(320, loaded.size.height))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(label)
                .contentShape(Rectangle())
                .onTapGesture { onTap?(loaded) }
                // Inert, a tap falls through to the row (a tool call's expand toggle).
                .allowsHitTesting(onTap != nil)
        } else {
            Label(label, systemImage: "photo")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var loaded: UIImage? {
        switch source {
        // ponytail: decodes inline bytes per render; cache by row if a long transcript of inline images stutters.
        case .inline(let data): UIImage(data: data)
        case .host(let path): image(path)
        case .unavailable: nil
        }
    }
}
