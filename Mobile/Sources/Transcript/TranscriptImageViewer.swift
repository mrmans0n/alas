import SwiftUI

/// A black full-screen viewer: pinch 1x to 4x, double-tap between 1x and 2.5x, share, close,
/// and swipe down to dismiss while at 1x. Nil `image` shows a spinner.
struct TranscriptImageViewer: View {
    let image: UIImage?
    let label: String
    @Environment(\.dismiss) private var dismiss
    @State private var zoomed = false
    @State private var dragY: CGFloat = 0

    /// Mostly vertical and downward, so a horizontal or diagonal swipe never dismisses.
    private static func isDownSwipe(_ t: CGSize) -> Bool { t.height > 0 && abs(t.height) > 2 * abs(t.width) }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            if let image {
                ZoomableImage(image: image, label: label, zoomed: $zoomed)
                    .ignoresSafeArea()
                    .offset(y: dragY)
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { if !zoomed, Self.isDownSwipe($0.translation) { dragY = $0.translation.height } }
                            .onEnded { value in
                                if !zoomed, Self.isDownSwipe(value.translation), value.translation.height > 100 { dismiss() }
                                withAnimation { dragY = 0 }
                            }
                    )
            } else {
                ProgressView().tint(.white).frame(maxHeight: .infinity)
            }
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").font(.title)
                }
                .accessibilityLabel("Close")
                Spacer()
                if let image {
                    ShareLink(item: Image(uiImage: image), preview: SharePreview(label, image: Image(uiImage: image))) {
                        Image(systemName: "square.and.arrow.up.circle.fill").font(.title)
                    }
                    .accessibilityLabel("Share")
                }
            }
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.white)
            .padding()
        }
        .preferredColorScheme(.dark)
    }
}

private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    let label: String
    @Binding var zoomed: Bool

    func makeCoordinator() -> Coordinator { Coordinator(zoomed: $zoomed) }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = CenteringScrollView()
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 4
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.delegate = context.coordinator
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = label
        imageView.accessibilityTraits = .image
        scroll.addSubview(imageView)
        scroll.imageView = imageView
        context.coordinator.imageView = imageView
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        let imageView = context.coordinator.imageView
        if imageView?.image !== image { imageView?.image = image }
        imageView?.accessibilityLabel = label
    }

    /// Sizes the image to the viewport at 1x (first layout, rotation) and centres it when smaller.
    final class CenteringScrollView: UIScrollView {
        weak var imageView: UIImageView?

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let imageView else { return }
            if zoomScale == 1 {
                imageView.frame = CGRect(origin: .zero, size: bounds.size)
                contentSize = bounds.size
            }
            var frame = imageView.frame
            frame.origin.x = max(0, (bounds.width - frame.width) / 2)
            frame.origin.y = max(0, (bounds.height - frame.height) / 2)
            imageView.frame = frame
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var imageView: UIImageView?
        @Binding var zoomed: Bool
        init(zoomed: Binding<Bool>) { _zoomed = zoomed }

        func viewForZooming(in _: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scroll: UIScrollView) {
            zoomed = scroll.zoomScale > 1.01
            scroll.setNeedsLayout()
        }

        @objc func doubleTap(_ tap: UITapGestureRecognizer) {
            guard let scroll = tap.view as? UIScrollView else { return }
            if scroll.zoomScale > 1 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let scale: CGFloat = 2.5
                let point = tap.location(in: imageView)
                let size = CGSize(width: scroll.bounds.width / scale, height: scroll.bounds.height / scale)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                       width: size.width, height: size.height), animated: true)
            }
        }
    }
}
