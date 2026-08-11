import AppKit
import SwiftUI

struct VerdictSheet: View {
    let pendingCount: Int
    var onSubmit: (ReviewVerdict, String) -> Void = { _, _ in }
    var onCancel: () -> Void = {}

    @State private var verdict: ReviewVerdict = .comment
    @State private var summaryBody = ""
    @Environment(\.theme) private var theme

    init(
        pendingCount: Int,
        initialVerdict: ReviewVerdict = .comment,
        onSubmit: @escaping (ReviewVerdict, String) -> Void = { _, _ in },
        onCancel: @escaping () -> Void = {}
    ) {
        self.pendingCount = pendingCount
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        _verdict = State(initialValue: initialVerdict)
    }

    static func canSubmit(verdict: ReviewVerdict, summaryBody: String) -> Bool {
        verdict != .requestChanges || !summaryBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSubmit: Bool {
        Self.canSubmit(verdict: verdict, summaryBody: summaryBody)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Finish your review")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(theme.color("fg"))
            if pendingCount > 0 {
                Text("\(pendingCount) pending comment\(pendingCount == 1 ? "" : "s")")
                    .font(.system(size: 12))
                    .foregroundColor(theme.color("fg-dim"))
            }

            verdictPicker

            VStack(alignment: .leading, spacing: 6) {
                Text(verdict == .requestChanges ? "Summary (required)" : "Summary (optional)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.color("fg-dim"))
                PairedTextEditor(
                    text: $summaryBody,
                    font: .systemFont(ofSize: 12),
                    textColor: NSColor(theme.color("fg"))
                )
                    .frame(minHeight: 80)
                    .background(theme.color("bg-1"))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(theme.color("line"), lineWidth: 0.75)
                    )
            }

            HStack(spacing: 10) {
                Button("Submit review") {
                    onSubmit(verdict, summaryBody)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .accessibilityIdentifier("verdict-submit-review")
                .disabled(!canSubmit)

                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.color("fg-muted"))
            }
        }
        .padding(20)
        .frame(width: 380)
        .background(theme.color("bg-2"))
        .presentationBackground(theme.color("bg-2"))
    }

    private var verdictPicker: some View {
        HStack(spacing: 0) {
            verdictButton(.approve, label: "Approve", systemName: "checkmark.circle")
            verdictButton(.requestChanges, label: "Request changes", systemName: "exclamationmark.circle")
            verdictButton(.comment, label: "Comment", systemName: "bubble.left")
        }
        .padding(3)
        .background(theme.color("bg-3"))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.color("line"), lineWidth: 0.75)
        )
    }

    private func verdictButton(_ v: ReviewVerdict, label: String, systemName: String) -> some View {
        let active = verdict == v
        return Button {
            verdict = v
        } label: {
            HStack(spacing: 4) {
                Image(systemName: systemName)
                    .font(.system(size: 11, weight: .medium))
                Text(label)
                    .font(.system(size: 11, weight: active ? .semibold : .regular))
            }
            .foregroundColor(active ? theme.color("fg") : theme.color("fg-muted"))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(active ? theme.color("bg-1") : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(label)
    }
}
