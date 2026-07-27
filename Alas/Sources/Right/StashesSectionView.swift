import SwiftUI

struct StashesSectionView: View {
    let stashes: [GitStash]
    let filesByRef: [String: [GitStashFile]]
    let loadingRefs: Set<String>
    @Binding var expanded: Bool
    let expandedRefs: Set<String>
    let onToggleSection: () -> Void
    let onToggleStash: (GitStash) -> Void
    let onSelectFile: (GitStash, GitStashFile) -> Void
    let onApply: (GitStash) -> Void
    let onPop: (GitStash) -> Void
    let onDrop: (GitStash) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        if !stashes.isEmpty {
            Section {
                if expanded {
                    ForEach(stashes) { stash in
                        stashRow(stash)
                    }
                }
            } header: {
                SectionHeader(
                    role: .stashes,
                    title: "Stashes",
                    count: stashes.count,
                    expanded: expanded,
                    onToggle: onToggleSection
                )
            }
        }
    }

    @ViewBuilder
    private func stashRow(_ stash: GitStash) -> some View {
        let open = expandedRefs.contains(stash.ref)
        Button {
            onToggleStash(stash)
        } label: {
            HStack(spacing: 6) {
                Icon(name: open ? "chev-down" : "chev-right", size: 10, color: theme.color("fg-faint"))
                    .frame(width: 14, height: 14)
                Text(stash.subject.isEmpty ? stash.ref : stash.subject)
                    .font(.system(size: 11.5))
                    .foregroundColor(theme.color("fg"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(stash.ref)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.color("fg-faint"))
                Spacer()
                if loadingRefs.contains(stash.ref) {
                    Spinner(lineWidth: 1.2, duration: 0.7)
                        .frame(width: 10, height: 10)
                }
                Menu {
                    Button("Apply") { onApply(stash) }
                    Button("Pop") { onPop(stash) }
                    Divider()
                    Button("Drop…", role: .destructive) { onDrop(stash) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.color("fg-muted"))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Stash actions")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Apply") { onApply(stash) }
            Button("Pop") { onPop(stash) }
            Divider()
            Button("Drop…", role: .destructive) { onDrop(stash) }
        }
        if open {
            expandedFiles(for: stash)
        }
    }

    @ViewBuilder
    private func expandedFiles(for stash: GitStash) -> some View {
        let files = filesByRef[stash.ref] ?? []
        if loadingRefs.contains(stash.ref) && files.isEmpty {
            HStack(spacing: 6) {
                Spinner(lineWidth: 1.2, duration: 0.7)
                    .frame(width: 10, height: 10)
                Text("Loading stash files…")
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("fg-faint"))
            }
            .padding(.leading, 32)
            .padding(.vertical, 6)
        } else if files.isEmpty {
            Text("no files")
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg-faint"))
                .padding(.leading, 32)
                .padding(.vertical, 6)
        } else {
            ForEach(files) { file in
                Button {
                    onSelectFile(stash, file)
                } label: {
                    HStack(spacing: 6) {
                        FileTypeIconView(filename: (file.path as NSString).lastPathComponent, size: 16)
                        Text((file.path as NSString).lastPathComponent)
                            .font(.system(size: 11.5, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if file.add > 0 {
                            Text("+\(file.add)")
                                .foregroundColor(theme.color("add"))
                        }
                        if file.del > 0 {
                            Text("-\(file.del)")
                                .foregroundColor(theme.color("del"))
                        }
                        StatusBadge(status: file.status)
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.leading, 32)
                    .padding(.trailing, 12)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
