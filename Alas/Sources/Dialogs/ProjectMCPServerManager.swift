import SwiftUI

struct ProjectMCPServerManager: View {
    @Environment(\.designScale) private var scale
    @Binding var servers: [ProjectMCPServer]
    let approvalQueue: RepoHookApprovalQueue

    @State private var draft: [ProjectMCPServer]
    @State private var editor: ProjectMCPServerEditorTarget?
    @State private var deleteTarget: ProjectMCPServer?
    @State private var didImportClipboard = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    init(servers: Binding<[ProjectMCPServer]>, approvalQueue: RepoHookApprovalQueue) {
        _servers = servers
        self.approvalQueue = approvalQueue
        _draft = State(initialValue: servers.wrappedValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("MCP Servers")
                .font(.system(size: 15, weight: .semibold)) // design-literal: the one dialog title
            Text("Servers are attached when a new agent session is created.")
                .font(scale.metaFont)
                .foregroundColor(theme.color("fg-dim"))
                .padding(.top, scale.space[0])
                .padding(.bottom, scale.space[4])

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if draft.isEmpty {
                        Text("No MCP servers configured")
                            .font(scale.metaFont)
                            .foregroundColor(theme.color("fg-dim"))
                            .frame(maxWidth: .infinity, minHeight: 88, alignment: .center)
                    } else {
                        ForEach(draft) { server in
                            serverRow(server)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 160, maxHeight: 340)

            HStack(spacing: 8) {
                AlasButton(title: "Add Server", icon: "plus", action: {
                    editor = .new
                })
                AlasButton(title: "Import from Clipboard", icon: "doc.on.clipboard", action: importFromClipboard)
                Spacer()
                AlasButton(title: "Cancel", style: .subtle, action: { dismiss() })
                AlasButton(title: "Done", style: .primary, action: commit)
                    .disabled(!ProjectMCPServerEditorPolicy.canSave(draft))
            }
            .padding(.top, scale.space[4])
        }
        .padding(scale.space[5])
        .frame(width: 620)
        .background(theme.color("bg-1"))
        .onAppear {
            guard !didImportClipboard else { return }
            didImportClipboard = true
            importFromClipboard()
        }
        .sheet(item: $editor) { target in
            ProjectMCPServerEditor(server: target.server) { saved in
                save(saved, replacing: target.existingID)
            }
            .modifier(RepoHookApprovalPresentationHandler(approvalQueue: approvalQueue))
        }
        .confirmationDialog(
            deleteConfirmationTitle,
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Server", role: .destructive) {
                if let deleteTarget {
                    draft.removeAll { $0.id == deleteTarget.id }
                }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("The server will not be attached to future sessions after you save the project.")
        }
        .modifier(RepoHookApprovalPresentationHandler(
            approvalQueue: approvalQueue,
            isActive: editor.map { _ in false } ?? true
        ))
    }

    private func serverRow(_ server: ProjectMCPServer) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(server.name.isEmpty ? "Unnamed server" : server.name)
                        .font(scale.meta.font(weight: .medium))
                        .foregroundColor(theme.color("fg"))
                    Text(ProjectMCPServerEditorPolicy.transportLabel(for: server.transport))
                        .font(scale.caption.font(weight: .regular))
                        .foregroundColor(theme.color("fg-muted"))
                }
                Text(ProjectMCPServerEditorPolicy.summary(for: server))
                    .font(scale.meta.font(design: .monospaced))
                    .foregroundColor(theme.color("fg-dim"))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            MCPServerIconButton(icon: "pencil", tooltip: "Edit \(server.name)") {
                editor = .existing(server)
            }
            MCPServerIconButton(icon: "trash", tooltip: "Delete \(server.name)") {
                deleteTarget = server
            }
        }
        .padding(scale.space[3])
        .background(theme.color("bg-0"))
        .overlay(
            RoundedRectangle(cornerRadius: scale.radius.medium)
                .strokeBorder(theme.color("line"), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: scale.radius.medium))
    }

    private func save(_ server: ProjectMCPServer, replacing existingID: String?) {
        if let existingID, let index = draft.firstIndex(where: { $0.id == existingID }) {
            draft[index] = server
        } else {
            draft.append(server)
        }
        editor = nil
    }

    private func commit() {
        guard ProjectMCPServerEditorPolicy.canSave(draft) else { return }
        servers = draft
        dismiss()
    }

    private func importFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        draft.append(contentsOf: ProjectMCPConfigImporter.servers(from: text, excluding: draft))
    }

    private var deleteConfirmationTitle: String {
        guard let deleteTarget, !deleteTarget.name.isEmpty else {
            return "Delete this MCP server?"
        }
        return "Delete \(deleteTarget.name)?"
    }
}

private enum ProjectMCPServerEditorTarget: Identifiable {
    case new
    case existing(ProjectMCPServer)

    var id: String {
        switch self {
        case .new: "new"
        case let .existing(server): server.id
        }
    }

    var existingID: String? {
        if case let .existing(server) = self { return server.id }
        return nil
    }

    var server: ProjectMCPServer {
        switch self {
        case .new:
            ProjectMCPServer.stdio(name: "", command: "")
        case let .existing(server):
            server
        }
    }
}

struct MCPServerIconButton: View {
    @Environment(\.designScale) private var scale
    let icon: String
    let tooltip: String
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Icon(name: icon, size: 11, color: theme.color("fg"))
                .frame(width: 28, height: 28)
                .background(theme.color("bg-3"))
                .overlay(
                    RoundedRectangle(cornerRadius: scale.radius.medium)
                        .strokeBorder(theme.color("line"), lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: scale.radius.medium))
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }
}
