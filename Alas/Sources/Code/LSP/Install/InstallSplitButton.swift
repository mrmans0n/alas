import SwiftUI

/// Install affordance shared by Settings → Code rows and the editor nudge.
///
/// Renders as one of three shapes depending on detected installers:
/// - **No installer detected:** a disabled "Install" button whose tooltip
///   lists which installers would make this work.
/// - **Single installer:** a plain "Install" button that runs that recipe.
/// - **Multiple installers:** a split button — primary "Install" runs the
///   first available recipe (catalog-ordered, our recommended pick), and
///   a caret-only menu lets the user pick a specific installer.
struct InstallSplitButton: View {
    let recipes: [InstallRecipe]
    let available: [(installer: DetectedInstaller, recipe: InstallRecipe)]
    let busy: Bool
    let onInstall: (DetectedInstaller, InstallRecipe) -> Void

    @Environment(\.theme) var theme

    var body: some View {
        if available.isEmpty {
            AlasButton(title: "Install", style: .subtle, action: {})
                .disabled(true)
                .help("Install one of: \(recipes.map { $0.installer.rawValue }.joined(separator: ", "))")
        } else if available.count == 1, let pair = available.first {
            AlasButton(title: busy ? "Installing…" : "Install", style: .subtle, action: {
                onInstall(pair.installer, pair.recipe)
            })
            .disabled(busy)
        } else if let first = available.first {
            HStack(spacing: 2) {
                AlasButton(title: busy ? "Installing…" : "Install", style: .subtle, action: {
                    onInstall(first.installer, first.recipe)
                })
                .disabled(busy)

                Menu {
                    ForEach(available, id: \.installer.kind) { pair in
                        Button("Install with \(pair.installer.kind.rawValue)") {
                            onInstall(pair.installer, pair.recipe)
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.color("fg-muted"))
                        .frame(width: 22, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(busy)
            }
        }
    }
}
