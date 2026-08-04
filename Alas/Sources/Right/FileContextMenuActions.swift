import AppKit
import SwiftUI

struct FileContextMenuTarget: Equatable {
    let kind: FileTreeNode.Kind
    let localURL: URL?

    static func resolve(
        kind: FileTreeNode.Kind,
        worktreePath: URL,
        relativePath: String,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> Self {
        guard !worktreePath.isRemoteAlasPath else { return Self(kind: kind, localURL: nil) }
        let url = worktreePath.appendingPathComponent(relativePath)
        return Self(kind: kind, localURL: fileExists(url) ? url : nil)
    }
}

enum FileContextMenuAction: Hashable {
    case openInAlas, open, openWith, viewAtHEAD, compareWithHEAD
    case fileHistory, copyRelativePath, copyFullPath, revealInFinder
}

struct FileContextMenuConfiguration: Equatable {
    let target: FileContextMenuTarget
    let actions: [FileContextMenuAction]

    static func workingTreeFile(target: FileContextMenuTarget) -> Self {
        var actions: [FileContextMenuAction] = [.openInAlas]
        if target.localURL != nil { actions += [.open, .openWith] }
        actions += [.viewAtHEAD, .compareWithHEAD, .fileHistory, .copyRelativePath, .copyFullPath]
        if target.localURL != nil { actions.append(.revealInFinder) }
        return Self(target: target, actions: actions)
    }

    static func filesTab(target: FileContextMenuTarget) -> Self {
        var actions: [FileContextMenuAction] = []
        if target.kind == .file { actions.append(.openInAlas) }
        if target.localURL != nil {
            actions.append(.open)
            if target.kind == .file { actions.append(.openWith) }
        }
        if target.kind == .file { actions.append(.fileHistory) }
        actions += [.copyRelativePath, .copyFullPath]
        if target.localURL != nil { actions.append(.revealInFinder) }
        return Self(target: target, actions: actions)
    }
}

struct FileContextMenuActions: View {
    let configuration: FileContextMenuConfiguration
    var onOpenInAlas: (() -> Void)? = nil
    var openInAlasEnabled = true
    var onViewAtHEAD: (() -> Void)? = nil
    var viewAtHEADEnabled = true
    var onCompareWithHEAD: (() -> Void)? = nil
    var onFileHistory: (() -> Void)? = nil
    var onCopyRelativePath: (() -> Void)? = nil
    var onCopyFullPath: (() -> Void)? = nil

    @ViewBuilder var body: some View {
        ForEach(configuration.actions, id: \.self) { action in
            switch action {
            case .openInAlas:
                Button("Open in Alas") { onOpenInAlas?() }
                    .disabled(!openInAlasEnabled || onOpenInAlas == nil)
            case .open:
                if let url = configuration.target.localURL {
                    Button("Open") { FileSystemOpen.open(url: url) }
                }
            case .openWith:
                if let url = configuration.target.localURL { openWithMenu(url: url) }
            case .viewAtHEAD:
                Button("View at HEAD") { onViewAtHEAD?() }
                    .disabled(!viewAtHEADEnabled || onViewAtHEAD == nil)
            case .compareWithHEAD:
                Button("Compare with HEAD") { onCompareWithHEAD?() }
                    .disabled(onCompareWithHEAD == nil)
            case .fileHistory:
                Button("File History") { onFileHistory?() }
                    .disabled(onFileHistory == nil)
            case .copyRelativePath:
                Button("Copy Relative Path") { onCopyRelativePath?() }
                    .disabled(onCopyRelativePath == nil)
            case .copyFullPath:
                Button("Copy Full Path") { onCopyFullPath?() }
                    .disabled(onCopyFullPath == nil)
            case .revealInFinder:
                if let url = configuration.target.localURL {
                    Button("Reveal in Finder") { FileSystemOpen.reveal(url: url) }
                }
            }
        }
    }

    @ViewBuilder private func openWithMenu(url: URL) -> some View {
        Menu("Open With") {
            let applications = FileSystemOpen.applications(for: url)
            if applications.isEmpty {
                Button("No Compatible Applications") {}.disabled(true)
            } else {
                ForEach(applications) { application in
                    Button { FileSystemOpen.open(url: url, with: application) } label: {
                        Label {
                            Text(application.menuTitle)
                        } icon: {
                            Image(nsImage: application.icon).resizable().frame(width: 16, height: 16)
                        }
                    }
                }
            }
        }
    }
}
