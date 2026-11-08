import SwiftUI

struct MergeConflictAgentProposalView: View {
    @Environment(\.designScale) private var scale
    let currentText: String
    let proposedText: String
    let fileExtension: String
    let codeFontFamily: String
    let codeFontSize: CGFloat
    let onApply: () -> Void
    let onCancel: () -> Void
    @Environment(\.theme) var theme

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    columnLabel("CURRENT")
                    MergeConflictColumnView(
                        text: currentText,
                        fileExtension: fileExtension,
                        codeFontFamily: codeFontFamily,
                        codeFontSize: codeFontSize
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                VStack(spacing: 0) {
                    columnLabel("AGENT PROPOSAL")
                    MergeConflictColumnView(
                        text: proposedText,
                        fileExtension: fileExtension,
                        codeFontFamily: codeFontFamily,
                        codeFontSize: codeFontSize
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            actions
        }
        .background(theme.color("bg-1"))
        .overlay(
            RoundedRectangle(cornerRadius: scale.radius.medium)
                .strokeBorder(theme.color("line"), lineWidth: 1)
        )
        .padding(scale.space[4])
    }

    private var header: some View {
        HStack(spacing: scale.space[2]) {
            Image(systemName: "sparkles")
                .foregroundColor(theme.color("accent"))
            Text("Review proposed resolution")
                .font(scale.titleFont)
            Spacer()
        }
        .padding(.horizontal, scale.space[3])
        .padding(.vertical, scale.space[2])
        .background(theme.color("bg-2"))
        .overlay(Divider(), alignment: .bottom)
    }

    private func columnLabel(_ text: String) -> some View {
        Text(text)
            .font(scale.caption.font(weight: .semibold))
            .textCase(.uppercase)
            .foregroundColor(theme.color("fg-dim"))
            .padding(.horizontal, scale.space[2])
            .padding(.vertical, scale.space[1])
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.color("bg-2"))
    }

    private var actions: some View {
        HStack(spacing: scale.space[2]) {
            Spacer()
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button("Apply", action: onApply)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(theme.color("accent"))
        }
        .padding(.horizontal, scale.space[3])
        .padding(.vertical, scale.space[2])
        .background(theme.color("bg-2"))
        .overlay(Divider(), alignment: .top)
    }
}
