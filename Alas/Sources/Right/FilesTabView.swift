import SwiftUI

struct FilesTabView: View {
    let nodes: [FileTreeNode]
    let fileTreeGeneration: Int
    @Binding var openPaths: Set<String>
    let onSelectFile: (FileTreeNode) -> Void
    let shouldAutoLoadChildren: (String, DirectoryChildrenState) -> Bool
    let onLoadChildren: (String) -> Void
    let showIgnored: Bool
    let revealPath: String?
    let revealTick: Int
    let onClearReveal: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                revealBar
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Self.filteredNodes(nodes, showIgnored: showIgnored)) { node in
                            renderNode(node, depth: 0)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: revealTick) { _, _ in
                    guard let path = revealPath else { return }
                    proxy.scrollTo("file:\(path)", anchor: .top)
                    proxy.scrollTo("dir:\(path)", anchor: .top)
                }
            }
        }
    }

    @ViewBuilder
    private var revealBar: some View {
        if let revealPath {
            HStack(spacing: 6) {
                Icon(name: "target", size: 12, color: theme.color("accent"))
                    .frame(width: 14, height: 14)
                Text(Self.revealDisplayName(for: revealPath))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.color("fg"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button(action: onClearReveal) {
                    Icon(name: "x", size: 10, color: theme.color("fg-dim"))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityLabel("Clear focused file highlight")
                .help("Clear focused file highlight")
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .padding(.vertical, 5)
            .background(theme.color("bg-3").opacity(0.92))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(theme.color("line").opacity(0.7))
                    .frame(height: 1)
            }
        }
    }

    private func renderNode(_ node: FileTreeNode, depth: Int) -> AnyView {
        if node.kind == .dir {
            let chain = Self.compactChain(from: node)
            let terminal = chain.terminal
            let open = openPaths.contains(terminal.path)
            let canExpand = !terminal.isSubmodule
            return AnyView(
                Group {
                    Button {
                        guard canExpand else { return }
                        if open {
                            for p in chain.chainPaths { openPaths.remove(p) }
                        } else {
                            for p in chain.chainPaths {
                                openPaths.insert(p)
                                onLoadChildren(p)
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if canExpand {
                                Icon(name: open ? "chev-down" : "chev-right", size: 10, color: theme.color("fg-faint"))
                                    .frame(width: 14, height: 14)
                            } else {
                                Color.clear.frame(width: 14, height: 14)
                            }
                            FolderIconView(
                                name: terminal.name,
                                path: terminal.path,
                                open: open,
                                fallbackColor: folderColor(for: terminal, open: open)
                            )
                            Text(chain.displayName)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundColor(rowForeground(for: terminal))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            if terminal.isSubmodule {
                                submodulePill
                            }
                            if let badge = terminal.badge {
                                StatusBadge(status: badge)
                            }
                            if isOffGit(terminal) {
                                visibilityPill(terminal)
                            }
                            if Self.showsInlineLoadingIndicator(for: terminal, open: open, canExpand: canExpand) {
                                Spinner(lineWidth: 1.5, duration: 0.7)
                                    .frame(width: 12, height: 12)
                                    .accessibilityLabel("Loading \(terminal.name)")
                            }
                        }
                        .padding(.leading, CGFloat(12 + depth * 14))
                        .padding(.trailing, 12)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .opacity(isOffGit(terminal) ? 0.72 : 1.0)
                        .overlay(alignment: .leading) {
                            if isOffGit(terminal) {
                                ghostRail(depth: depth)
                            }
                        }
                        .contentShape(Rectangle())
                        .background(terminal.path == revealPath ? theme.color("bg-hover") : Color.clear)
                        .id("dir:\(terminal.path)")
                    }
                    .buttonStyle(.plain)
                    if open && canExpand {
                        switch terminal.childrenState {
                        case .loading, .loaded:
                            renderChildren(of: terminal, depth: depth + 1)
                        case .failed:
                            treeMessage("Could not load children", depth: depth + 1)
                            renderChildren(of: terminal, depth: depth + 1)
                        case .notLoaded:
                            EmptyView()
                        }
                    }
                }
                .task(id: loadTaskID(for: terminal, open: open)) {
                    if shouldAutoLoadChildren(for: terminal, open: open) {
                        onLoadChildren(terminal.path)
                    }
                }
            )
        } else {
            return AnyView(
                Button { onSelectFile(node) } label: {
                    HStack(spacing: 6) {
                        FileTypeIconView(filename: node.name, size: 18)
                        Text(node.name)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundColor(rowForeground(for: node))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if isOffGit(node) {
                            visibilityPill(node)
                        }
                        if let badge = node.badge {
                            StatusBadge(status: badge)
                        }
                    }
                    .padding(.leading, CGFloat(12 + depth * 14 + 14))
                    .padding(.trailing, 12)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(isOffGit(node) ? 0.72 : 1.0)
                    .overlay(alignment: .leading) {
                        if isOffGit(node) {
                            ghostRail(depth: depth)
                        }
                    }
                    .contentShape(Rectangle())
                    .background(node.path == revealPath ? theme.color("bg-hover") : Color.clear)
                    .id(node.id)
                }
                .buttonStyle(.plain)
            )
        }
    }

    private func loadTaskID(for node: FileTreeNode, open: Bool) -> String {
        "\(fileTreeGeneration):\(node.path):\(open):\(node.childrenState.rawValue)"
    }

    private func shouldAutoLoadChildren(for node: FileTreeNode, open: Bool) -> Bool {
        open && shouldAutoLoadChildren(node.path, node.childrenState)
    }

    nonisolated static func showsInlineLoadingIndicator(
        for node: FileTreeNode,
        open: Bool,
        canExpand: Bool
    ) -> Bool {
        open && canExpand && node.kind == .dir && node.childrenState == .loading
    }

    private func renderChildren(of node: FileTreeNode, depth: Int) -> some View {
        Group {
            if let kids = node.children {
                ForEach(Self.filteredNodes(kids, showIgnored: showIgnored)) {
                    renderNode($0, depth: depth)
                }
            }
        }
    }

    nonisolated static func filteredNodes(
        _ nodes: [FileTreeNode],
        showIgnored: Bool
    ) -> [FileTreeNode] {
        guard !showIgnored else { return nodes }
        return nodes.compactMap { node in
            let offGit = node.visibility == .ignored || node.visibility == .excluded
            // Files: drop if ignored/excluded.
            if node.kind == .file {
                return offGit ? nil : node
            }
            // Directories: filter children first. An ignored directory may
            // still contain tracked descendants (gitignore rules don't
            // un-track a path that's already in the index), so we only drop
            // the directory if it has no visible children left.
            var copy = node
            let visibleChildren = filteredNodes(node.children ?? [], showIgnored: showIgnored)
            copy.children = visibleChildren
            if offGit && visibleChildren.isEmpty {
                return nil
            }
            return copy
        }
    }

    nonisolated static func revealDisplayName(for path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    nonisolated static func compactChain(
        from node: FileTreeNode
    ) -> (displayName: String, chainPaths: [String], terminal: FileTreeNode) {
        var displayParts = [node.name]
        var chainPaths = [node.path]
        var current = node
        while true {
            guard
                current.kind == .dir,
                !current.isSubmodule,
                current.childrenState == .loaded,
                let children = current.children,
                children.count == 1,
                children[0].kind == .dir,
                !children[0].isSubmodule,
                children[0].childrenState == .loaded
            else { break }
            let next = children[0]
            displayParts.append(next.name)
            chainPaths.append(next.path)
            current = next
        }
        return (displayParts.joined(separator: "/"), chainPaths, current)
    }

    private func isOffGit(_ node: FileTreeNode) -> Bool {
        node.visibility == .ignored || node.visibility == .excluded
    }

    private func rowForeground(for node: FileTreeNode) -> Color {
        isOffGit(node) ? theme.color("fg-dim") : theme.color("fg")
    }

    private func folderColor(for node: FileTreeNode, open: Bool) -> Color {
        if isOffGit(node) {
            return theme.color("fg-dim")
        }
        return open ? theme.color("accent") : theme.color("fg-dim")
    }

    private func visibilityPill(_ node: FileTreeNode) -> some View {
        Text(node.visibility.rawValue)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundColor(theme.color("fg-dim"))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(theme.color("bg-4").opacity(0.75))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private var submodulePill: some View {
        Text("submodule")
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundColor(theme.color("submodule"))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(theme.color("submodule").opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private func ghostRail(depth: Int) -> some View {
        Rectangle()
            .fill(theme.color("fg-faint").opacity(0.55))
            .frame(width: 2)
            .padding(.leading, CGFloat(8 + depth * 14))
            .padding(.vertical, 4)
    }

    private func treeMessage(_ text: String, depth: Int) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(theme.color("fg-faint"))
            .padding(.leading, CGFloat(12 + depth * 14 + 14))
            .padding(.trailing, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
