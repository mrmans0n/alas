import AlasRemoteKit
import SwiftUI

/// A markdown or tool-call image: full width, never upscaled, at most 320 pt tall.
/// It reads as its label with a spinner while loading, and as the label alone when it cannot load.
struct TranscriptImage: View {
    let source: RemoteTranscriptImageSource
    /// Tried when `source` fails, as the Mac falls back to an asset's uri when its data is not an image.
    var fallback: RemoteTranscriptImageSource?
    let label: String
    /// Loads through the session's caches; without one the image reads as its label.
    let session: TranscriptSession?
    /// Opens the viewer once there is an image; nil leaves it inert.
    var onTap: ((UIImage) -> Void)?

    var body: some View {
        switch load {
        case .loaded(let image):
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: image.size.width, maxHeight: min(320, image.size.height))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(label)
                .contentShape(Rectangle())
                .onTapGesture { onTap?(image) }
                // Inert, a tap falls through to the row (a tool call's expand toggle).
                .allowsHitTesting(onTap != nil)
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                caption
            }
        case .failed:
            Label { caption } icon: { Image(systemName: "photo") }
                .foregroundStyle(.secondary)
        }
    }

    private var caption: some View {
        Text(label).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
    }

    private var load: TranscriptSession.ImageLoad {
        guard let session else { return .failed }
        let load = session.transcriptImage(source)
        if case .failed = load, let fallback, fallback != source { return session.transcriptImage(fallback) }
        return load
    }
}
