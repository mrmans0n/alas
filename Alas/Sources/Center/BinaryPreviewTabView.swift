import AppKit
import SwiftUI

struct BinaryPreviewTabView: View {
    let worktreePath: URL
    let relativePath: String
    let onRevealInFiles: (String) -> Void
    @Environment(\.theme) private var theme

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
                            onRevealInFinder: isRemote ? nil : { FileSystemOpen.reveal(url: folderURL(for: pathPrefix)) },
                            onFocusInFiles: relativePath.hasPrefix("/") ? nil : { onRevealInFiles(pathPrefix) },
                            onCopyFullPath: { Clipboard.copy(folderURL(for: pathPrefix).path) }
                        ))
                    }
                }
            )
            placeholder
        }
        .background(theme.color("bg-1"))
    }

    private var isRemote: Bool {
        worktreePath.isRemoteAlasPath
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.fill")
                .font(.system(size: 30))
                .foregroundColor(theme.color("fg-faint"))
            Text((relativePath as NSString).lastPathComponent)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(theme.color("fg"))
            Text("Binary file")
                .font(.system(size: 12))
                .foregroundColor(theme.color("fg-dim"))
            if !isRemote {
                HStack(spacing: 10) {
                    Button("Open with System") { FileSystemOpen.open(url: absoluteURL) }
                    Button("Reveal in Finder") { FileSystemOpen.reveal(url: absoluteURL) }
                }
                .padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var absoluteURL: URL {
        if relativePath.hasPrefix("/") {
            return URL(fileURLWithPath: relativePath)
        }
        return worktreePath.appendingPathComponent(relativePath)
    }

    private func folderURL(for pathPrefix: String) -> URL {
        if relativePath.hasPrefix("/") {
            return URL(fileURLWithPath: pathPrefix)
        }
        return worktreePath.appendingPathComponent(pathPrefix)
    }
}
