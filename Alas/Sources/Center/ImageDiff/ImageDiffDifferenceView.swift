import SwiftUI
import AppKit

struct ImageDiffDifferenceView: View {
    let before: NSImage
    let after: NSImage
    /// Reported up to the toolbar so the "X% changed" chip can display.
    /// Set asynchronously after the first compute completes.
    @Binding var percentChanged: Double?

    @State private var result: ImageDiffDifferenceComputer.Result?
    @State private var computing = false
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            Color.black
            if let mask = result?.mask {
                Image(nsImage: mask)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
            } else if computing {
                ProgressView()
            }
        }
        .clipped()
        .task(id: identityKey) { await compute() }
    }

    private var identityKey: String {
        // NSImage isn't Hashable; use pointer identity. Re-compute when
        // either reference changes — sufficient since the parent re-creates
        // these images only when the underlying tab key changes.
        "\(ObjectIdentifier(before).hashValue):\(ObjectIdentifier(after).hashValue)"
    }

    private func compute() async {
        guard result == nil else { return }
        computing = true
        defer { computing = false }
        // Background queue — the computer is CPU-heavy on large images.
        let captured = (before, after)
        let r: ImageDiffDifferenceComputer.Result = await Task.detached(priority: .userInitiated) {
            ImageDiffDifferenceComputer.compute(
                before: captured.0, after: captured.1
            )
        }.value
        result = r
        if r.totalPixels > 0 {
            percentChanged = Double(r.changedPixelCount) / Double(r.totalPixels) * 100.0
        }
    }
}
