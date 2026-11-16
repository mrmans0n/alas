import SwiftUI

/// A black full-screen viewer: pinch 1x to 4x, double-tap between 1x and 2.5x, share, close,
/// and swipe down to dismiss while at 1x. Nil `image` shows a spinner.
struct TranscriptImageViewer: View {
    let image: UIImage?
    let label: String
    @Environment(\.dismiss) private var dismiss
    @State private var zoomed = false
    @State private var dragY: CGFloat = 0

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            if let image {
                ZoomableImage(image: image, label: label, zoomed: $zoomed)
                    .ignoresSafeArea()
                    .offset(y: dragY)
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { if !zoomed { dragY = max(0, $0.translation.height) } }
                            .onEnded { value in
                                if !zoomed, value.translation.height > 120 { dismiss() }
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
        let scroll = UIScrollView()
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
        // The scroll view's size is only known after layout; size the content to it at 1x.
        if scroll.zoomScale == 1 { imageView?.frame = CGRect(origin: .zero, size: scroll.bounds.size) }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var imageView: UIImageView?
        @Binding var zoomed: Bool
        init(zoomed: Binding<Bool>) { _zoomed = zoomed }

        func viewForZooming(in _: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scroll: UIScrollView) {
            zoomed = scroll.zoomScale > 1.01
            // Keep a smaller-than-viewport image centered while zooming.
            guard let view = imageView else { return }
            let dx = max(0, (scroll.bounds.width - view.frame.width) / 2)
            let dy = max(0, (scroll.bounds.height - view.frame.height) / 2)
            scroll.contentInset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
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
