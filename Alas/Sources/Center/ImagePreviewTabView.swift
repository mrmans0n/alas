import AppKit
import SwiftUI

struct ImagePreviewTabView: View {
    let worktreePath: URL
    let relativePath: String
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
                            onCopyFullPath: { Clipboard.copy(absoluteURL.path) },
                            onRevealInFinder: isRemote ? nil : { FileSystemOpen.reveal(url: absoluteURL) },
                            onOpenWithSystem: isRemote ? nil : { FileSystemOpen.open(url: absoluteURL) }
                        ))
                    } else {
                        return .folder(BreadcrumbFolderMenu(
                            onRevealInFinder: isRemote ? nil : { FileSystemOpen.reveal(url: worktreePath.appendingPathComponent(pathPrefix)) },
                            onFocusInFiles: { onRevealInFiles(pathPrefix) },
                            onCopyFullPath: { Clipboard.copy(worktreePath.appendingPathComponent(pathPrefix).path) }
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
        worktreePath.isRemoteAlasPath
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
                icon: "photo.badge.exclamationmark",
                onOpenWithSystem: isRemote ? nil : { FileSystemOpen.open(url: absoluteURL) }
            )
        case .unsupported:
            previewMessage(title: "No Preview", detail: "This file type is not supported.", icon: "photo",
                           onOpenWithSystem: isRemote ? nil : { FileSystemOpen.open(url: absoluteURL) })
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
                if !isRemote {
                    Button("Open with System") { FileSystemOpen.open(url: absoluteURL) }
                        .buttonStyle(.borderless)
                    Button("Reveal in Finder") { FileSystemOpen.reveal(url: absoluteURL) }
                        .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(theme.color("bg-1"))
            .overlay(Divider().opacity(0.5), alignment: .top)
        }
    }

    private func previewMessage(title: String, detail: String, icon: String, onOpenWithSystem: (() -> Void)? = nil) -> some View {
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
            if let onOpenWithSystem {
                Button("Open with System") { onOpenWithSystem() }
                    .padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var absoluteURL: URL {
        worktreePath.appendingPathComponent(relativePath)
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

        guard let image = NSImage(data: data) else {
            loadState = .decodeFailed
            return
        }

        loadState = .loaded(ImagePreviewInfo(
            image: image,
            pixelSize: pixelSize(for: image),
            byteCount: Int64(data.count)
        ))
    }

    private func pixelSize(for image: NSImage) -> CGSize {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return image.size
        }
        return CGSize(width: cgImage.width, height: cgImage.height)
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
