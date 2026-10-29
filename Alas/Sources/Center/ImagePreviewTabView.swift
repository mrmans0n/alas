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
        worktreePath.isRemoteAlasPath
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
    let info: ImagePreviewInfo
    let name: String
    /// The local file behind the footer's Open with System and Reveal in Finder; nil hides them.
    var fileURL: URL?
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                Image(nsImage: info.image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            }
            .padding(18)
            footer
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(name)
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
            if let fileURL {
                Button("Open with System") { FileSystemOpen.open(url: fileURL) }
                    .buttonStyle(.borderless)
                Button("Reveal in Finder") { FileSystemOpen.reveal(url: fileURL) }
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(theme.color("bg-1"))
        .overlay(Divider().opacity(0.5), alignment: .top)
    }
}

/// A centered icon, title and detail standing in for a file's preview.
struct FilePreviewMessage: View {
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
}
