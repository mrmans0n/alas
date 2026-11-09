import AppKit
import SwiftUI

struct ImagePreviewTabView: View {
    let worktreePath: URL
    let relativePath: String
    var externalAbsolutePath: String? = nil
    let onRevealInFiles: (String) -> Void
    var onStartupRecoveryReady: () -> Void = {}
    @Environment(\.theme) private var theme
    @State private var loadState: LoadState = .idle

    var body: some View {
        VStack(spacing: 0) {
            BreadcrumbView(
                relativePath: relativePath,
                onRevealInFiles: onRevealInFiles,
                menuItems: { index, pathPrefix in
                    let isLast = index == relativePath.split(separator: "/").count - 1
                    if isLast {
                        return .file(BreadcrumbFileMenu(
                            onCopyRelativePath: { Clipboard.copy(relativePath) },
                            onCopyFullPath: { Clipboard.copyPath(absoluteURL.path) },
                            onRevealInFinder: isRemote ? nil : { FileSystemOpen.reveal(url: absoluteURL) },
                            onOpenWithSystem: isRemote ? nil : { FileSystemOpen.open(url: absoluteURL) }
                        ))
                    } else {
                        return .folder(BreadcrumbFolderMenu(
                            onRevealInFinder: isRemote ? nil : { FileSystemOpen.reveal(url: worktreePath.appendingPathComponent(pathPrefix)) },
                            onFocusInFiles: { onRevealInFiles(pathPrefix) },
                            onCopyFullPath: { Clipboard.copyPath(worktreePath.appendingPathComponent(pathPrefix).path) }
                        ))
                    }
                }
            )
            content
        }
        .background(theme.color("bg-1"))
        .task(id: absoluteURL) {
            await loadImage()
            onStartupRecoveryReady()
        }
    }

    private var isRemote: Bool {
        absoluteURL.isRemoteAlasPath
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .idle, .loading:
            FilePreviewMessage(title: "Loading Preview", detail: relativePath, icon: "photo")
        case .missing:
            FilePreviewMessage(title: "File Not Found", detail: relativePath, icon: "exclamationmark.triangle")
        case .decodeFailed:
            FilePreviewMessage.decodeFailed(onOpenWithSystem: isRemote ? nil : { FileSystemOpen.open(url: absoluteURL) })
        case .unsupported:
            FilePreviewMessage(title: "No Preview", detail: "This file type is not supported.", icon: "photo",
                               onOpenWithSystem: isRemote ? nil : { FileSystemOpen.open(url: absoluteURL) })
        case .loaded(let info):
            ImagePreviewBody(info: info, name: (relativePath as NSString).lastPathComponent,
                             fileURL: isRemote ? nil : absoluteURL)
        }
    }

    private var absoluteURL: URL {
        if let externalAbsolutePath { return URL(fileURLWithPath: externalAbsolutePath) }
        return worktreePath.appendingPathComponent(relativePath)
    }

    private func loadImage() async {
        loadState = .loading

        guard ImageFileType.isSupported(relativePath: relativePath) else {
            loadState = .unsupported
            return
        }

        let url = absoluteURL
        let data: Data
        if let host = RemoteHostRegistry.shared.host(forPath: url.path) {
            do {
                switch try await RemoteFileAccess.read(host: host, path: url.path) {
                case let .file(contents, _): data = contents
                case .missing, .directory, .symlink:
                    loadState = .missing
                    return
                case .unreadable:
                    loadState = .decodeFailed
                    return
                }
            } catch {
                loadState = .missing
                return
            }
        } else {
            guard FileManager.default.fileExists(atPath: url.path), let contents = try? Data(contentsOf: url) else {
                loadState = .missing
                return
            }
            data = contents
        }

        guard let info = ImagePreviewInfo(data: data) else {
            loadState = .decodeFailed
            return
        }
        loadState = .loaded(info)
    }
}

private enum LoadState {
    case idle
    case loading
    case loaded(ImagePreviewInfo)
    case missing
    case unsupported
    case decodeFailed
}

struct ImagePreviewInfo {
    let image: NSImage
    let pixelSize: CGSize
    let byteCount: Int64?

    /// Nil when `data` does not decode as an image.
    init?(data: Data) {
        guard let image = NSImage(data: data) else { return nil }
        self.image = image
        var rect = CGRect(origin: .zero, size: image.size)
        pixelSize = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
            .map { CGSize(width: $0.width, height: $0.height) } ?? image.size
        byteCount = Int64(data.count)
    }

    var metadata: String {
        let dimensions = "\(Int(pixelSize.width)) x \(Int(pixelSize.height))"
        guard let byteCount else { return dimensions }
        return "\(dimensions) | \(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file))"
    }
}

/// A decoded image above a footer with its name, pixel size and byte count.
struct ImagePreviewBody: View {
    @Environment(\.designScale) private var scale
    let info: ImagePreviewInfo
    let name: String
    /// The local file behind the footer's Open with System and Reveal in Finder; nil hides them.
    var fileURL: URL?
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            ZoomableImageView(image: info.image)
            footer
        }
    }

    private var footer: some View {
        HStack(spacing: scale.space[2]) {
            Text(name)
                .font(scale.meta.font(weight: .medium, design: .monospaced))
                .foregroundColor(theme.color("fg"))
                .lineLimit(1)
                .truncationMode(.middle)
            Text("|")
                .foregroundColor(theme.color("fg-faint"))
            Text(info.metadata)
                .font(scale.metaFont)
                .foregroundColor(theme.color("fg-dim"))
                .lineLimit(1)
            Spacer()
            if let fileURL {
                Button("Open with System") { FileSystemOpen.open(url: fileURL) }
                    .buttonStyle(.borderless)
                Button("Reveal in Finder") { FileSystemOpen.reveal(url: fileURL) }
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, scale.space[3])
        .frame(height: 28)
        .background(theme.color("bg-1"))
        .overlay(Divider().opacity(0.5), alignment: .top)
    }
}

/// Native magnification handles trackpad pinches and scrolling even when hosted
/// in a floating preview panel. The same viewport is used by image tabs.
struct ZoomableImageView: View {
    @Environment(\.designScale) private var scale
    let image: NSImage
    @State private var controls = ImageViewportControls()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: scale.space[3]) {
                Button { controls.zoom(by: 0.8) } label: {
                    Label("Zoom out", systemImage: "minus.magnifyingglass")
                }
                Button("Actual Size") { controls.actualSize() }
                Button("Fit") { controls.fit() }
                Button { controls.zoom(by: 1.25) } label: {
                    Label("Zoom in", systemImage: "plus.magnifyingglass")
                }
                Spacer(minLength: 0)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(scale.space[3])
            ImageViewport(image: image, controls: controls)
        }
    }
}

@MainActor
private final class ImageViewportControls {
    weak var viewport: ImageScrollView?

    func zoom(by factor: CGFloat) {
        guard let viewport else { return }
        viewport.fitsViewport = false
        viewport.setMagnification(
            min(viewport.maxMagnification, max(viewport.minMagnification, viewport.magnification * factor)),
            centeredAt: viewport.contentView.bounds.center
        )
    }

    func actualSize() {
        guard let viewport else { return }
        viewport.fitsViewport = false
        viewport.setMagnification(1, centeredAt: viewport.contentView.bounds.center)
    }

    func fit() {
        viewport?.fitsViewport = true
        viewport?.fitImage()
    }
}

private struct ImageViewport: NSViewRepresentable {
    let image: NSImage
    let controls: ImageViewportControls

    func makeNSView(context: Context) -> ImageScrollView {
        let view = ImageScrollView()
        controls.viewport = view
        view.setImage(image)
        return view
    }

    func updateNSView(_ nsView: ImageScrollView, context: Context) {
        controls.viewport = nsView
        nsView.setImage(image)
    }
}

private final class ImageScrollView: NSScrollView {
    var fitsViewport = true
    private var lastViewportSize = CGSize.zero
    private let imageView = PannableImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        borderType = .noBorder
        contentView = CenteredImageClipView()
        contentView.drawsBackground = false
        allowsMagnification = true
        minMagnification = 0.001
        maxMagnification = 32
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.setAccessibilityLabel("Image preview")
        documentView = imageView
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setImage(_ image: NSImage) {
        guard imageView.image !== image else { return }
        imageView.image = image
        imageView.frame = NSRect(origin: .zero, size: image.size)
        fitsViewport = true
        lastViewportSize = .zero
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard contentSize != lastViewportSize else { return }
        lastViewportSize = contentSize
        if fitsViewport { fitImage() }
    }

    func fitImage() {
        let size = imageView.frame.size
        guard size.width > 0, size.height > 0, contentSize.width > 0, contentSize.height > 0 else { return }
        let scale = min(1, contentSize.width / size.width, contentSize.height / size.height)
        minMagnification = min(0.001, scale)
        setMagnification(scale, centeredAt: imageView.bounds.center)
    }

    override func magnify(with event: NSEvent) {
        fitsViewport = false
        super.magnify(with: event)
    }
}

private final class CenteredImageClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var result = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return result }
        if result.width > documentView.frame.width {
            result.origin.x = (documentView.frame.width - result.width) / 2
        }
        if result.height > documentView.frame.height {
            result.origin.y = (documentView.frame.height - result.height) / 2
        }
        return result
    }
}

private final class PannableImageView: NSImageView {
    private var dragOrigin = CGPoint.zero
    private var scrollOrigin = CGPoint.zero

    override func mouseDown(with event: NSEvent) {
        dragOrigin = event.locationInWindow
        scrollOrigin = enclosingScrollView?.contentView.bounds.origin ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard let scrollView = enclosingScrollView else { return }
        let scale = scrollView.magnification
        var proposedBounds = scrollView.contentView.bounds
        proposedBounds.origin = CGPoint(
            x: scrollOrigin.x + (dragOrigin.x - event.locationInWindow.x) / scale,
            y: scrollOrigin.y + (dragOrigin.y - event.locationInWindow.y) / scale
        )
        scrollView.contentView.scroll(to: scrollView.contentView.constrainBoundsRect(proposedBounds).origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

/// A centered icon, title and detail standing in for a file's preview.
struct FilePreviewMessage: View {
    @Environment(\.designScale) private var scale
    let title: String
    let detail: String
    let icon: String
    var onOpenWithSystem: (() -> Void)?
    @Environment(\.theme) private var theme

    static func decodeFailed(onOpenWithSystem: (() -> Void)? = nil) -> FilePreviewMessage {
        FilePreviewMessage(
            title: "Cannot Preview Image",
            detail: "The file could not be decoded as an image.",
            icon: "photo.badge.exclamationmark",
            onOpenWithSystem: onOpenWithSystem
        )
    }

    var body: some View {
        VStack(spacing: scale.space[3]) {
            Image(systemName: icon)
                .font(.system(size: 30)) // design-literal: hero icon
                .foregroundColor(theme.color("fg-faint"))
            Text(title)
                .font(.system(size: 15, weight: .semibold)) // design-literal: hero title
                .foregroundColor(theme.color("fg"))
            Text(detail)
                .font(scale.metaFont)
                .foregroundColor(theme.color("fg-dim"))
                .lineLimit(3)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .frame(maxWidth: 420)
            if let onOpenWithSystem {
                Button("Open with System") { onOpenWithSystem() }
                    .padding(.top, scale.space[1])
            }
        }
        .padding(scale.space[5])
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
