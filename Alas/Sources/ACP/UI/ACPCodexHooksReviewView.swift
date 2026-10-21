import SwiftUI

struct ACPCodexHooksReviewView: View {
    @ObservedObject var coordinator: ACPCodexHooksReviewCoordinator

    var body: some View {
        if let presentation = coordinator.presentation {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Review Codex hooks").font(.headline)
                    Spacer()
                    if presentation.isBusy { ProgressView().controlSize(.small) }
                }
                Text("Execution host: \(presentation.context.host)").font(.caption)
                Text(presentation.context.cwd).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if let snapshot = presentation.snapshot {
                    if let home = snapshot.codexHome {
                        Text("CODEX_HOME: \(home)").font(.caption).textSelection(.enabled)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(rows(snapshot)) { row in
                                hookRow(row.hook, snapshot: snapshot, presentationID: presentation.id)
                                Divider()
                            }
                            ForEach(diagnostics(snapshot), id: \.id) { diagnostic in
                                Text(diagnostic.text).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 280)
                    .disabled(presentation.isBusy)
                }
                if let error = presentation.error {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                Text("Codex stores trusted hashes in CODEX_HOME/config.toml, shared with Codex CLI and projects using that home. Trusting a different hash for the same key replaces its previous trust.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Refresh") { Task { await coordinator.refresh(presentationID: presentation.id) } }.disabled(presentation.isBusy)
                    Button("Cancel") { coordinator.cancel(presentationID: presentation.id) }
                    Spacer(minLength: 0)
                }
                HStack {
                    Button("Continue without trusting") { coordinator.continueWithoutTrusting(presentationID: presentation.id) }
                        .disabled(presentation.isBusy || presentation.snapshot == nil)
                    Spacer(minLength: 0)
                    Button("Trust selected and continue") { Task { await coordinator.trustSelectedAndContinue(presentationID: presentation.id) } }
                        .disabled(presentation.isBusy || coordinator.selection.isEmpty)
                }
            }
            .padding(14)
            .frame(maxWidth: 640)
            .background(.regularMaterial, in: .rect(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).stroke(.quaternary) }
        }
    }

    private func hookRow(_ hook: ACPCodexHook, snapshot: ACPCodexHooksList, presentationID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { coordinator.selection.contains(hook.identity) },
                set: { coordinator.setSelected(hook.identity, selected: $0, presentationID: presentationID) }
            )) {
                Text(hook.key).font(.caption.weight(.semibold)).textSelection(.enabled)
            }
            .toggleStyle(.checkbox)
            .disabled(!hook.canTrust || !snapshot.isUnique(hook.identity))
            Text("\(hook.eventName) · \(hook.handlerType) · \(hook.trustStatus)")
                .font(.caption).foregroundStyle(.secondary)
            Text(target(hook)).font(.caption.monospaced()).lineLimit(3).textSelection(.enabled)
            Text(hook.sourcePath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text("\(hook.enabled ? "Enabled" : "Disabled") · \(hook.isManaged ? "Managed" : "Unmanaged") · \(hook.source)")
                .font(.caption).foregroundStyle(.secondary)
            if !hook.isKnown || !snapshot.isUnique(hook.identity) {
                Text("Unknown or duplicate definition. This hook cannot be trusted here.").font(.caption).foregroundStyle(.orange)
            }
            DisclosureGroup("Details") {
                VStack(alignment: .leading, spacing: 3) {
                    Text(target(hook)).font(.caption.monospaced()).fixedSize(horizontal: false, vertical: true)
                    Text("Hash: \(hook.currentHash)")
                    if let matcher = hook.matcher { Text("Matcher: \(matcher)") }
                    Text("Timeout: \(hook.timeoutSec) seconds")
                    if let status = hook.statusMessage { Text(status) }
                    if let plugin = hook.pluginId { Text("Plugin: \(plugin)") }
                }
                .font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)
        }
    }

    private func target(_ hook: ACPCodexHook) -> String {
        switch hook.handlerType {
        case "command": hook.command ?? "Command unavailable"
        case "mcpTool": "\(hook.server ?? "Unknown server") / \(hook.tool ?? "Unknown tool")"
        case "prompt", "agent": "The adapter does not expose the full definition. Review its metadata and hash."
        default: "Handler details unavailable"
        }
    }

    private struct Diagnostic: Identifiable {
        let id: String
        let text: String
    }
    private func diagnostics(_ snapshot: ACPCodexHooksList) -> [Diagnostic] {
        var occurrences: [String: Int] = [:]
        return (snapshot.warnings + snapshot.errors.map { "\($0.path)\n\($0.message)" }).map { text in
            let occurrence = occurrences[text, default: 0]
            occurrences[text] = occurrence + 1
            return Diagnostic(id: "\(text)\u{0}\(occurrence)", text: text)
        }
    }

    private struct Row: Identifiable {
        let id: String
        let hook: ACPCodexHook
    }
    private func rows(_ snapshot: ACPCodexHooksList) -> [Row] {
        var occurrences: [ACPCodexHookIdentity: Int] = [:]
        return snapshot.hooks.map { hook in
            let occurrence = occurrences[hook.identity, default: 0]
            occurrences[hook.identity] = occurrence + 1
            return Row(id: "\(hook.key)\u{0}\(hook.currentHash)\u{0}\(occurrence)", hook: hook)
        }
    }
}
