import SwiftUI

struct GGRestackPresentation: Equatable, Identifiable {
    let prepared: GGPreparedRestack

    var id: String {
        "\(prepared.snapshot.stackName):\(prepared.snapshot.headSHA)"
    }

    var hasWork: Bool {
        prepared.plan.entriesRestacked > 0 || prepared.plan.steps.contains { $0.action != "ok" }
    }
}

struct GGRestackSheet: View {
    let presentation: GGRestackPresentation
    let onApply: () async throws -> Void
    let onCancel: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale
    @Environment(\.dismiss) private var dismiss
    @State private var isApplying = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: scale.space[3]) {
            Text("Restack")
                .font(.system(size: 15, weight: .semibold)) // design-literal: the one dialog title
            Text(presentation.hasWork
                 ? "Review the rewrite plan before applying it."
                 : "This stack is already correctly based.")
                .font(scale.meta.font)
                .foregroundStyle(theme.color("fg-dim"))

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(presentation.prepared.plan.steps, id: \.ggID) { step in
                        HStack(spacing: scale.space[3]) {
                            Text("\(step.position)")
                                .font(scale.caption.font(weight: .regular, design: .monospaced))
                                .foregroundStyle(theme.color("fg-faint"))
                                .frame(width: 24, alignment: .trailing)
                            VStack(alignment: .leading, spacing: scale.space[0]) {
                                Text(step.title)
                                    .font(scale.meta.font(weight: .medium))
                                    .lineLimit(1)
                                Text(stepDetail(step))
                                    .font(scale.caption.font(weight: .regular, design: .monospaced))
                                    .foregroundStyle(theme.color("fg-faint"))
                                    .lineLimit(1)
                            }
                            Spacer(minLength: scale.space[2])
                            Text(step.action)
                                .font(scale.caption.font(weight: .semibold))
                                .foregroundStyle(step.action == "ok" ? theme.color("add") : theme.color("warn"))
                        }
                        .frame(minHeight: 44)
                        .padding(.horizontal, scale.space[3])
                        .background(theme.color("bg-2").opacity(0.45))
                        if step.ggID != presentation.prepared.plan.steps.last?.ggID {
                            Divider()
                        }
                    }
                }
            }
            .frame(minWidth: 540, minHeight: 230)
            .clipShape(.rect(cornerRadius: scale.radius.medium))

            if let errorMessage {
                Text(errorMessage)
                    .font(scale.meta.font)
                    .foregroundStyle(theme.color("warn"))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: scale.space[2]) {
                Spacer()
                Button("Cancel") {
                    onCancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isApplying)
                Button("Apply Restack") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!presentation.hasWork || isApplying)
            }
        }
        .padding(scale.space[4])
        .interactiveDismissDisabled(isApplying)
    }

    private func stepDetail(_ step: GGRestackStep) -> String {
        switch (step.currentParent, step.expectedParent) {
        case let (current?, expected?): "\(current) → \(expected)"
        case let (current?, nil): current
        case let (nil, expected?): expected
        case (nil, nil): step.ggID
        }
    }

    private func apply() {
        guard presentation.hasWork, !isApplying else { return }
        isApplying = true
        errorMessage = nil
        Task { @MainActor in
            do {
                try await onApply()
                dismiss()
            } catch {
                errorMessage = GGErrorPresentation.message(for: error)
                isApplying = false
            }
        }
    }
}
