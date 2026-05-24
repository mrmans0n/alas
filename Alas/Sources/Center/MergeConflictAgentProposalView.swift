import SwiftUI

struct MergeConflictAgentProposalView: View {
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
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(theme.color("line"), lineWidth: 1)
        )
        .padding(20)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .foregroundColor(theme.color("accent"))
            Text("Review proposed resolution")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.color("bg-2"))
        .overlay(Divider(), alignment: .bottom)
    }

    private func columnLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .textCase(.uppercase)
            .foregroundColor(theme.color("fg-dim"))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.color("bg-2"))
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button("Apply", action: onApply)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(theme.color("accent"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.color("bg-2"))
        .overlay(Divider(), alignment: .top)
    }
}
