import AppKit
import SwiftUI

/// Shared layout for prompt-editor windows (Commit, Merge Resolve all,
/// Merge Resolve file). Pulls out the title + textarea + footer
/// structure so each prompt type only has to declare its title,
/// description, draft binding, and the actions.
struct PromptEditorBody: View {
    @Environment(\.designScale) private var scale
    let windowTitle: String
    let title: String
    let description: String
    @Binding var draftPrompt: String
    let onReset: () -> Void
    let onCancel: () -> Void
    let onSave: () -> Void
    let theme: Theme

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(SettingsPaneStyle.titleFont)
                    Text(description)
                        .font(scale.metaFont)
                        .foregroundColor(theme.color("fg-dim"))
                }
                PairedTextEditor(
                    text: $draftPrompt,
                    font: scale.meta.monospacedNSFont(),
                    codeBlockStyle: .standard(
                        theme: theme,
                        baseFont: scale.meta.monospacedNSFont(),
                        baseColor: .labelColor,
                        monoSize: scale.meta.size
                    )
                )
                    .background(theme.color("bg-2"))
                    .overlay(
                        RoundedRectangle(cornerRadius: scale.radius.medium)
                            .stroke(theme.color("line-soft"), lineWidth: 0.5)
                    )
            }
            .padding(.horizontal, scale.space[5])
            .padding(.vertical, scale.space[5])
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.color("bg-1"))
            footer
        }
        .frame(minWidth: 720, minHeight: 560)
        .background(theme.color("bg-1"))
        .background(WindowConfigurator())
        .environment(\.theme, theme)
        .ignoresSafeArea()
    }

    private var header: some View {
        ZStack {
            LinearGradient(
                colors: [theme.color("bg-3"), theme.color("bg-2")],
                startPoint: .top,
                endPoint: .bottom
            )
            HStack {
                TrafficLights()
                Spacer()
            }
            .padding(.leading, scale.space[4])
            Text(windowTitle)
                .font(scale.meta.font(weight: .medium))
                .foregroundColor(theme.color("fg-muted"))
        }
        .frame(height: 44)
        .overlay(Divider().opacity(0.5), alignment: .bottom)
    }

    /// Footer mirrors the AgentEditView pattern: subtle destructive /
    /// reset action on the left, Cancel + primary save on the right.
    /// Keeps the alignment consistent across settings dialogs.
    private var footer: some View {
        HStack(spacing: 8) {
            AlasButton(title: "Reset to Default", style: .subtle, action: onReset)
            Spacer()
            AlasButton(title: "Cancel", style: .subtle, action: onCancel)
            AlasButton(title: "Save", style: .primary, action: onSave)
        }
        .padding(.horizontal, scale.space[5])
        .padding(.vertical, scale.space[3])
        .background(theme.color("bg-2"))
        .overlay(Divider().opacity(0.5), alignment: .top)
    }
}
