import SwiftUI

/// Install affordance shared by Settings → Code rows and the editor nudge.
/// Visual style mirrors `AiSplitButton` in the right-sidebar commit composer:
/// a single rounded rect with a primary action on the left and (when there's
/// more than one detected installer) an attached caret menu on the right.
///
/// Renders as one of three shapes:
/// - **No installer detected:** a disabled "Install" pill whose tooltip
///   lists installers that would unlock it.
/// - **Single installer:** the primary pill on its own, running that recipe.
/// - **Multiple installers:** primary pill + caret menu. The primary runs
///   the first-available (catalog-ordered, our recommended pick); the menu
///   lets the user pick a different installer.
struct InstallSplitButton: View {
    let recipes: [InstallRecipe]
    let available: [(installer: DetectedInstaller, recipe: InstallRecipe)]
    let busy: Bool
    let onInstall: (DetectedInstaller, InstallRecipe) -> Void

    @Environment(\.theme) var theme

    private var label: String { busy ? "Installing…" : "Install" }
    private var hasInstaller: Bool { !available.isEmpty }
    private var primaryDisabled: Bool { busy || !hasInstaller }

    var body: some View {
        HStack(spacing: 1) {
            primaryButton
            if available.count > 1 {
                caretMenu
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder
    private var primaryButton: some View {
        Button(action: runPrimary) {
            Text(label)
                .font(.system(size: 11))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .foregroundColor(primaryDisabled ? theme.color("fg-faint") : theme.color("fg"))
                .background(theme.color("bg-3"))
        }
        .buttonStyle(.plain)
        .disabled(primaryDisabled)
        .help(hasInstaller
              ? (available.count > 1
                 ? "Install with \(available[0].installer.kind.rawValue)"
                 : "Install with \(available[0].installer.kind.rawValue)")
              : "Install one of: \(recipes.map { $0.installer.rawValue }.joined(separator: ", "))")
    }

    @ViewBuilder
    private var caretMenu: some View {
        Menu {
            ForEach(available, id: \.installer.kind) { pair in
                Button("Install with \(pair.installer.kind.rawValue)") {
                    onInstall(pair.installer, pair.recipe)
                }
            }
        } label: {
            Icon(name: "chev-down", size: 9, color: theme.color("fg-faint"))
                .padding(.horizontal, 7).padding(.vertical, 7)
                .background(theme.color("bg-3"))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(busy)
        .help("Choose installer")
    }

    private func runPrimary() {
        guard let first = available.first else { return }
        onInstall(first.installer, first.recipe)
    }
}
