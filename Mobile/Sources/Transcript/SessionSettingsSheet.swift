import AlasRemoteKit
import SwiftUI

/// Model, thinking, mode and the agent's own options, built from what the agent reports.
struct SessionSettingsSheet: View {
    var session: TranscriptSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let config = session.config {
                    if let chips = config.chips {
                        chipSection("Model", chips.model) { session.setModel($0) }
                        chipSection("Thinking", chips.thinking) { route($0, chips.thinking) }
                        chipSection("Mode", chips.mode) { session.setMode($0) }
                        ForEach(chips.parameters, id: \.id) { p in
                            chipSection(p.label, p.chip) { route($0, p.chip) }
                        }
                        if !chips.booleans.isEmpty {
                            Section {
                                ForEach(chips.booleans, id: \.id) { option in
                                    Toggle(option.name, isOn: Binding(
                                        get: { option.value },
                                        set: { session.setConfigOption(option.id, value: .boolean($0)) }))
                                }
                            }
                        }
                        if chips.autoRun == "supported" { autoRun(config) }
                    } else {
                        flat("Model", config.models, current: config.currentModel) { session.setModel($0) }
                        flat("Mode", config.modes, current: config.currentMode) { session.setMode($0) }
                        autoRun(config)
                    }
                }
            }
            .navigationTitle("Session Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func autoRun(_ config: RemoteSessionConfig) -> some View {
        Section {
            Toggle("Auto-run", isOn: Binding(get: { config.autoRunEnabled }, set: { session.setAutoRun($0) }))
        }
    }

    /// Routes a pick by the chip's source, as the web's `sendChip` does.
    private func route(_ id: String, _ chip: RemoteChip?) {
        guard let chip else { return }
        switch chip.source {
        case "model": session.setModel(id)
        case "mode": session.setMode(id)
        default:
            if let configId = chip.configId { session.setConfigOption(configId, value: .string(id)) }
        }
    }

    @ViewBuilder
    private func chipSection(_ title: String, _ chip: RemoteChip?, pick: @escaping (String) -> Void) -> some View {
        if let chip, !chip.options.isEmpty {
            Section(title) {
                Picker(title, selection: Binding(get: { chip.currentId ?? "" }, set: pick)) {
                    ForEach(chip.options, id: \.id) { option in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(option.name)
                                if option.id == chip.recommendedId {
                                    Text("Recommended").font(.caption2).foregroundStyle(.tint)
                                }
                            }
                            if let d = option.description, !d.isEmpty {
                                Text(d).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(option.id)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
    }

    @ViewBuilder
    private func flat(_ title: String, _ items: [RemoteModelInfo], current: String?, pick: @escaping (String) -> Void) -> some View {
        if !items.isEmpty {
            Section(title) {
                Picker(title, selection: Binding(get: { current ?? "" }, set: pick)) {
                    ForEach(items, id: \.id) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
    }
}
