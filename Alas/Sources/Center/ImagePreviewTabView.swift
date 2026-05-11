import AppKit
import SwiftUI

struct ImagePreviewTabView: View {
    let worktreePath: URL
    let relativePath: String
    @Environment(\.theme) private var theme
    @State private var loadState: LoadState = .idle

    var body: some View {
        VStack(spacing: 0) {
            breadcrumb
            content
        }
        .background(theme.color("bg-1"))
        .task(id: absoluteURL) {
            loadImage()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .idle, .loading:
            previewMessage(title: "Loading Preview", detail: relativePath, icon: "photo")
        case .missing:
            previewMessage(title: "File Not Found", detail: relativePath, icon: "exclamationmark.triangle")
        case .decodeFailed:
            previewMessage(
                title: "Cannot Preview Image",
                detail: "The file could not be decoded as an image.",
                icon: "photo.badge.exclamationmark"
            )
        case .unsupported:
            previewMessage(title: "No Preview", detail: "This file type is not supported.", icon: "photo")
        case .loaded(let info):
            loadedPreview(info)
        }
    }

    private func loadedPreview(_ info: ImagePreviewInfo) -> some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                Image(nsImage: info.image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            }
            .padding(18)

            HStack(spacing: 8) {
                Text((relativePath as NSString).lastPathComponent)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.color("fg"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("|")
                    .foregroundColor(theme.color("fg-faint"))
                Text(info.metadata)
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("fg-dim"))
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(theme.color("bg-1"))
            .overlay(Divider().opacity(0.5), alignment: .top)
        }
    }

    private func previewMessage(title: String, detail: String, icon: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 30))
                .foregroundColor(theme.color("fg-faint"))
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(theme.color("fg"))
            Text(detail)
                .font(.system(size: 12))
                .foregroundColor(theme.color("fg-dim"))
                .lineLimit(3)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .frame(maxWidth: 420)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var breadcrumb: some View {
        let components = relativePath.split(separator: "/")
        let lastIndex = components.count - 1
        return HStack(spacing: 6) {
            ForEach(Array(components.enumerated()), id: \.offset) { (i, comp) in
                Text(comp)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(i == lastIndex ? theme.color("fg") : theme.color("fg-muted"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if i < lastIndex {
                    Text("/").foregroundColor(theme.color("fg-faint"))
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(theme.color("bg-1"))
        .overlay(Divider().opacity(0.5), alignment: .bottom)
    }

    private var absoluteURL: URL {
        worktreePath.appendingPathComponent(relativePath)
    }

    private func loadImage() {
        loadState = .loading

        guard ImageFileType.isSupported(relativePath: relativePath) else {
            loadState = .unsupported
            return
        }

        let url = absoluteURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            loadState = .missing
            return
        }

        guard let image = NSImage(contentsOf: url) else {
            loadState = .decodeFailed
            return
        }

        loadState = .loaded(ImagePreviewInfo(
            image: image,
            pixelSize: pixelSize(for: image),
            byteCount: byteCount(for: url)
        ))
    }

    private func pixelSize(for image: NSImage) -> CGSize {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return image.size
        }
        return CGSize(width: cgImage.width, height: cgImage.height)
    }

    private func byteCount(for url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return nil }
        return Int64(size)
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

private struct ImagePreviewInfo {
    let image: NSImage
    let pixelSize: CGSize
    let byteCount: Int64?

    var metadata: String {
        let dimensions = "\(Int(pixelSize.width)) x \(Int(pixelSize.height))"
        guard let byteCount else { return dimensions }
        return "\(dimensions) | \(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file))"
    }
}
