import SwiftUI

/// Overlay shown above the editor when the on-disk file diverges from
/// the dirty buffer (`changedOnDisk` / `deletedOnDisk`) or when the
/// last save failed (`lastSaveError`). The banner is a single horizontal
/// strip so it doesn't shift the editor's scroll geometry.
struct EditorConflictBanner: View {
    let buffer: EditorBuffer
    @Environment(\.theme) var theme

    var body: some View {
        if let error = buffer.lastSaveError {
            row(message: "Couldn't save: \(error)", action: nil)
        } else if let conflict = buffer.conflict {
            switch conflict {
            case .changedOnDisk:
                row(
                    message: "File changed on disk while you have unsaved edits.",
                    primary: ("Reload from disk", { buffer.resolveConflictReloadingFromDisk() }),
                    secondary: ("Keep mine", { buffer.resolveConflictKeepingMine() })
                )
            case .deletedOnDisk:
                row(
                    message: "File was deleted on disk.",
                    primary: ("Save anyway", { try? buffer.save(); buffer.resolveConflictKeepingMine() }),
                    secondary: ("Keep mine", { buffer.resolveConflictKeepingMine() })
                )
            }
        }
    }

    @ViewBuilder
    private func row(message: String, action: (label: String, run: () -> Void)?) -> some View {
        HStack(spacing: 10) {
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(theme.color("fg"))
            Spacer()
            if let action {
                Button(action.label, action: action.run)
                    .buttonStyle(.borderless)
                    .font(.system(size: 12))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(theme.color("bg-3"))
        .overlay(Divider().opacity(0.5), alignment: .bottom)
    }

    @ViewBuilder
    private func row(message: String, primary: (label: String, run: () -> Void), secondary: (label: String, run: () -> Void)) -> some View {
        HStack(spacing: 10) {
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(theme.color("fg"))
            Spacer()
            Button(secondary.label, action: secondary.run).buttonStyle(.borderless).font(.system(size: 12))
            Button(primary.label, action: primary.run).buttonStyle(.borderless).font(.system(size: 12)).foregroundColor(theme.color("accent"))
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(theme.color("bg-3"))
        .overlay(Divider().opacity(0.5), alignment: .bottom)
    }
}
