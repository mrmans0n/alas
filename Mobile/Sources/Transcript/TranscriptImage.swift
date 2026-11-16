import SwiftUI

/// A markdown or tool-call image: full width, never upscaled, at most 320 pt tall.
/// It reads as its label with a spinner while loading, and as the label alone when it cannot load.
struct TranscriptImage: View {
    /// Where the image sits, the row's id and its block or asset index: inline data is keyed by it.
    let id: String
    /// A markdown image source or an asset's uri.
    let source: String
    /// An asset's base64 data, tried before `source`. Passed undecoded: the session decodes it off the main actor.
    var data: String?
    let label: String
    /// Loads through the session's caches; without one the image reads as its label.
    let session: TranscriptSession?
    /// Held here, not read from the cache, so an eviction cannot close the open viewer.
    @State private var presented: Presented?

    private struct Presented: Identifiable {
        let id = UUID()
        let image: UIImage
    }

    var body: some View {
        content
            .fullScreenCover(item: $presented) { TranscriptImageViewer(image: $0.image, label: label) }
    }

    @ViewBuilder
    private var content: some View {
        switch load {
        case .loaded(let image):
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: image.size.width, maxHeight: min(320, image.size.height))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(label)
                .contentShape(Rectangle())
                .onTapGesture { presented = Presented(image: image) }
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
        session?.transcriptImage(id: id, source: source, data: data) ?? .failed
    }
}
