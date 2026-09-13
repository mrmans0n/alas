import Observation
import SwiftUI

@MainActor @Observable
final class WorkspaceEditPreviewModel {
    let plan: WorkspaceEditPlan
    let diffs: [[DiffLine]]
    private let applyPlan: (WorkspaceEditPlan) async -> WorkspaceEditOutcome
    private(set) var isApplying = false
    private(set) var errorMessage: String?
    private(set) var requiresRecovery = false
    private(set) var didApply = false
    private var applicationTask: Task<WorkspaceEditOutcome, Never>?
    private var isCancelled = false

    init(plan: WorkspaceEditPlan, apply: @escaping (WorkspaceEditPlan) async -> WorkspaceEditOutcome) {
        self.plan = plan
        self.diffs = plan.steps.map(Self.diff)
        self.applyPlan = apply
    }

    var fileCount: Int { Set(plan.steps.flatMap { [$0.document, $0.destination].compactMap { $0 } }).count }

    struct DiffLine: Identifiable, Equatable {
        let id: Int
        let prefix: String
        let text: String
    }

    static func diff(_ step: WorkspaceEditPlanStep) -> [DiffLine] {
        let beforeSnapshot = step.kind == .rename && step.after.document == step.destination && step.destinationBefore?.content != nil
            ? step.destinationBefore ?? step.before : step.before
        let before = String(data: beforeSnapshot.content ?? Data(), encoding: .utf8) ?? ""
        let after = String(data: step.after.content ?? Data(), encoding: .utf8) ?? ""
        let old = before.isEmpty ? [] : before.components(separatedBy: "\n")
        let new = after.isEmpty ? [] : after.components(separatedBy: "\n")
        let difference = new.difference(from: old)
        var removed: Set<Int> = []
        var inserted: Set<Int> = []
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var rows: [DiffLine] = []
        var a = 0
        var b = 0
        while a < old.count || b < new.count {
            if a < old.count, removed.contains(a) {
                rows.append(.init(id: rows.count, prefix: "−", text: old[a]))
                a += 1
            } else if b < new.count, inserted.contains(b) {
                rows.append(.init(id: rows.count, prefix: "+", text: new[b]))
                b += 1
            } else if a < old.count, b < new.count {
                rows.append(.init(id: rows.count, prefix: " ", text: new[b]))
                a += 1
                b += 1
            } else { break }
        }
        return rows
    }

    func apply() async -> Bool {
        guard !isApplying, !requiresRecovery, !isCancelled else { return false }
        isApplying = true
        errorMessage = nil
        defer { isApplying = false
        applicationTask = nil }
        let task = Task { await applyPlan(plan) }
        applicationTask = task
        let outcome = await withTaskCancellationHandler {
            await task.value
        } onCancel: { task.cancel() }
        errorMessage = Self.message(for: outcome)
        if case .recoveryRequired = outcome { requiresRecovery = true }
        if case .applied = outcome { didApply = true
        return true }
        return false
    }

    func cancel() {
        isCancelled = true
        applicationTask?.cancel()
    }

    static func message(for outcome: WorkspaceEditOutcome) -> String? {
        switch outcome {
        case .applied: nil
        case .conflict(let documents):
            "Files changed. Run the command again: " + documents.map { URL(string: $0.uri)?.path ?? $0.uri }.joined(separator: ", ")
        case .recovered(let reason): "Changes were not applied. " + reason
        case .recoveryRequired(let id, let reason): "Recovery required (\(id.uuidString)). " + reason
        }
    }
}

/// Selection only changes the inspected diff. Apply always receives the full immutable plan.
struct WorkspaceEditPreview: View {
    let model: WorkspaceEditPreviewModel
    let close: () -> Void
    @State private var selectedStep: Int = 0

    private struct StepRow: Identifiable {
        let id: Int
        let step: WorkspaceEditPlanStep
        var path: String { URL(string: step.document.uri)?.path ?? step.document.uri }
        var directory: String { (path as NSString).deletingLastPathComponent }
    }

    private var rows: [StepRow] { model.plan.steps.enumerated().map { StepRow(id: $0.offset, step: $0.element) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Review workspace changes").font(.headline)
                Spacer()
                Text("\(model.fileCount) files · \(model.plan.steps.count) operations").foregroundStyle(.secondary)
            }
            HSplitView {
                List(selection: $selectedStep) {
                    ForEach(Array(Set(rows.map(\.directory))).sorted(), id: \.self) { directory in
                        Section(directory) {
                            ForEach(rows.filter { $0.directory == directory }) { row in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text((row.path as NSString).lastPathComponent)
                                        Spacer()
                                        Text(row.step.kind.rawValue.capitalized).font(.caption2)
                                            .padding(.horizontal, 4).background(.quaternary, in: .rect(cornerRadius: 3))
                                    }
                                    Text(row.step.before.isOpen ? "Unsaved buffer" : "Disk").font(.caption).foregroundStyle(.secondary)
                                    if let destination = row.step.destination {
                                        Text("To " + (URL(string: destination.uri)?.path ?? destination.uri)).font(.caption).foregroundStyle(.secondary)
                                        if row.step.destinationBefore?.isDirty == true {
                                            Text("Destination has unsaved changes").font(.caption).foregroundStyle(.orange)
                                        }
                                    }
                                }.tag(row.id)
                            }
                        }
                    }
                }.frame(minWidth: 210, idealWidth: 240)
                ScrollView([.horizontal, .vertical]) {
                    if model.plan.steps.indices.contains(selectedStep) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(model.diffs[selectedStep]) { line in
                                Text(line.prefix + " " + line.text)
                                    .foregroundStyle(line.prefix == "+" ? Color.green : line.prefix == "−" ? Color.red : Color.primary)
                                    .textSelection(.enabled)
                            }
                        }.font(.system(.body, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                }.frame(minWidth: 350)
            }
            ForEach(model.plan.reviewAnnotations.keys.sorted(), id: \.self) { key in
                if let annotation = model.plan.reviewAnnotations[key] {
                    Text(annotation.label + (annotation.description.map { ": " + $0 } ?? "")).font(.caption)
                }
            }
            if !model.plan.warnings.isEmpty {
                Text("These resource operations replace or delete unsaved content. Review every affected file before applying.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let error = model.errorMessage { Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled) }
            HStack {
                Text("All changes apply together. Open text buffers are not saved.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.isApplying { ProgressView().controlSize(.small) }
                Button("Cancel", action: close).keyboardShortcut(.cancelAction).disabled(model.isApplying)
                Button("Apply all") { Task { if await model.apply() { close() } } }
                    .keyboardShortcut(.defaultAction).disabled(model.isApplying || model.requiresRecovery)
            }
        }.padding(16).frame(width: 820, height: 540)
    }
}
