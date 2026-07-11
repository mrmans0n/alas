import SwiftUI

private enum ProjectMCPTransportEditorKind: String, CaseIterable, Hashable {
    case stdio
    case http
    case sse

    init(_ transport: ProjectMCPTransport) {
        switch transport {
        case .stdio: self = .stdio
        case .http: self = .http
        case .sse: self = .sse
        }
    }

    var title: String {
        switch self {
        case .stdio: "Stdio"
        case .http: "HTTP"
        case .sse: "Legacy SSE"
        }
    }
}

struct ProjectMCPServerEditor: View {
    let onSave: (ProjectMCPServer) -> Void

    @State private var draft: ProjectMCPServer
    @State private var transportKind: ProjectMCPTransportEditorKind
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    init(server: ProjectMCPServer, onSave: @escaping (ProjectMCPServer) -> Void) {
        self.onSave = onSave
        _draft = State(initialValue: server)
        _transportKind = State(initialValue: ProjectMCPTransportEditorKind(server.transport))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(draft.name.isEmpty ? "Add MCP Server" : "Edit MCP Server")
                .font(.system(size: 16, weight: .semibold))
                .padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    field(label: "Name") {
                        AlasField(text: $draft.name, placeholder: "filesystem")
                    }
                    field(label: "Transport") {
                        Seg(value: $transportKind, options: ProjectMCPTransportEditorKind.allCases.map { ($0, $0.title) })
                            .onChange(of: transportKind) { _, newValue in
                                replaceTransport(with: newValue)
                            }
                    }
                    transportFields
                    templateHelp
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 470)

            if let validationMessage {
                Text(validationMessage)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .padding(.top, 10)
            }

            HStack(spacing: 8) {
                Spacer()
                AlasButton(title: "Cancel", style: .subtle, action: { dismiss() })
                AlasButton(title: "Save", style: .primary, action: save)
                    .disabled(!canSave)
            }
            .padding(.top, 16)
        }
        .padding(24)
        .frame(width: 620)
        .background(theme.color("bg-1"))
    }

    @ViewBuilder
    private var transportFields: some View {
        switch draft.transport {
        case .stdio:
            field(label: "Command") {
                AlasField(text: commandBinding, placeholder: "npx", monospaced: true)
            }
            argumentEditor
            keyValueEditor(title: "Environment", entries: environmentBinding, valuePlaceholder: "${TOKEN}")
        case .http, .sse:
            field(label: "URL") {
                AlasField(text: urlBinding, placeholder: "https://mcp.example.com", monospaced: true)
            }
            if transportKind == .sse {
                Text("Legacy SSE is supported for older MCP servers. Prefer HTTP for new servers.")
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("fg-muted"))
            }
            keyValueEditor(title: "Headers", entries: headersBinding, valuePlaceholder: "${MCP_TOKEN}")
        }
    }

    private var argumentEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Arguments")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(theme.color("fg"))
            ForEach(argumentValues.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    AlasField(text: argumentBinding(at: index), placeholder: "--root", monospaced: true)
                    MCPServerIconButton(icon: "trash", tooltip: "Remove argument") {
                        removeArgument(at: index)
                    }
                }
            }
            AlasButton(title: "Add Argument", icon: "plus", style: .subtle, action: addArgument)
        }
    }

    private func keyValueEditor(
        title: String,
        entries: Binding<[MCPKeyValue]>,
        valuePlaceholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(theme.color("fg"))
            ForEach(entries.wrappedValue.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    AlasField(text: keyValueNameBinding(entries, at: index), placeholder: title == "Headers" ? "Authorization" : "NAME", monospaced: true)
                    AlasField(text: keyValueValueBinding(entries, at: index), placeholder: valuePlaceholder, monospaced: true)
                    MCPServerIconButton(icon: "trash", tooltip: "Remove \(title.lowercased()) entry") {
                        entries.wrappedValue.remove(at: index)
                    }
                }
            }
            AlasButton(title: "Add \(title == "Headers" ? "Header" : "Variable")", icon: "plus", style: .subtle) {
                entries.wrappedValue.append(MCPKeyValue(id: UUID().uuidString, name: "", value: ""))
            }
        }
    }

    private var templateHelp: some View {
        Text("Use ${VAR} for environment values. PROJECT_DIR and WORKTREE_DIR are available automatically. Put secret values in environment variables, then reference them here.")
            .font(.system(size: 11))
            .foregroundColor(theme.color("fg-muted"))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var canSave: Bool {
        ProjectMCPServerEditorPolicy.canSave([draft])
    }

    private var validationMessage: String? {
        guard !canSave else { return nil }
        return "Complete the server name and transport fields, and use unique variable or header names."
    }

    private var commandBinding: Binding<String> {
        Binding(
            get: {
                if case let .stdio(command, _, _) = draft.transport { return command }
                return ""
            },
            set: { value in
                guard case let .stdio(_, args, environment) = draft.transport else { return }
                draft.transport = .stdio(command: value, args: args, environment: environment)
            }
        )
    }

    private var urlBinding: Binding<String> {
        Binding(
            get: {
                switch draft.transport {
                case let .http(url, _), let .sse(url, _): url
                case .stdio: ""
                }
            },
            set: { value in
                switch draft.transport {
                case let .http(_, headers): draft.transport = .http(url: value, headers: headers)
                case let .sse(_, headers): draft.transport = .sse(url: value, headers: headers)
                case .stdio: break
                }
            }
        )
    }

    private var argumentValues: [String] {
        if case let .stdio(_, args, _) = draft.transport { return args }
        return []
    }

    private func argumentBinding(at index: Int) -> Binding<String> {
        Binding(
            get: { argumentValues.indices.contains(index) ? argumentValues[index] : "" },
            set: { value in
                guard case .stdio(let command, var args, let environment) = draft.transport,
                      args.indices.contains(index) else { return }
                args[index] = value
                draft.transport = .stdio(command: command, args: args, environment: environment)
            }
        )
    }

    private var environmentBinding: Binding<[MCPKeyValue]> {
        Binding(
            get: {
                if case let .stdio(_, _, environment) = draft.transport { return environment }
                return []
            },
            set: { value in
                guard case let .stdio(command, args, _) = draft.transport else { return }
                draft.transport = .stdio(command: command, args: args, environment: value)
            }
        )
    }

    private var headersBinding: Binding<[MCPKeyValue]> {
        Binding(
            get: {
                switch draft.transport {
                case let .http(_, headers), let .sse(_, headers): headers
                case .stdio: []
                }
            },
            set: { value in
                switch draft.transport {
                case let .http(url, _): draft.transport = .http(url: url, headers: value)
                case let .sse(url, _): draft.transport = .sse(url: url, headers: value)
                case .stdio: break
                }
            }
        )
    }

    private func keyValueNameBinding(_ entries: Binding<[MCPKeyValue]>, at index: Int) -> Binding<String> {
        Binding(
            get: { entries.wrappedValue.indices.contains(index) ? entries.wrappedValue[index].name : "" },
            set: { value in
                guard entries.wrappedValue.indices.contains(index) else { return }
                entries.wrappedValue[index].name = value
            }
        )
    }

    private func keyValueValueBinding(_ entries: Binding<[MCPKeyValue]>, at index: Int) -> Binding<String> {
        Binding(
            get: { entries.wrappedValue.indices.contains(index) ? entries.wrappedValue[index].value : "" },
            set: { value in
                guard entries.wrappedValue.indices.contains(index) else { return }
                entries.wrappedValue[index].value = value
            }
        )
    }

    private func replaceTransport(with newKind: ProjectMCPTransportEditorKind) {
        guard newKind != ProjectMCPTransportEditorKind(draft.transport) else { return }
        switch (draft.transport, newKind) {
        case let (.http(url, headers), .sse):
            draft.transport = .sse(url: url, headers: headers)
        case let (.sse(url, headers), .http):
            draft.transport = .http(url: url, headers: headers)
        case (.stdio, .http):
            draft.transport = .http(url: "", headers: [])
        case (.stdio, .sse):
            draft.transport = .sse(url: "", headers: [])
        case (.http, .stdio), (.sse, .stdio):
            draft.transport = .stdio(command: "", args: [], environment: [])
        case (.stdio, .stdio), (.http, .http), (.sse, .sse):
            break
        }
    }

    private func addArgument() {
        guard case let .stdio(command, args, environment) = draft.transport else { return }
        draft.transport = .stdio(command: command, args: args + [""], environment: environment)
    }

    private func removeArgument(at index: Int) {
        guard case .stdio(let command, var args, let environment) = draft.transport,
              args.indices.contains(index) else { return }
        args.remove(at: index)
        draft.transport = .stdio(command: command, args: args, environment: environment)
    }

    private func field<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(theme.color("fg"))
            content()
        }
    }

    private func save() {
        guard canSave else { return }
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(draft)
    }
}
