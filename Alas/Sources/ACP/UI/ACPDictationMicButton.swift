import SwiftUI

/// The composer's push-to-talk button, with the language menu on
/// right-click. Shared by the local and peer composers.
struct ACPDictationMicButton: View {
    @ObservedObject var dictation: ACPDictationService
    /// Languages ready to use without a download, for the menu.
    let installedLocales: [String]
    /// Current value of the `acpDictationLocale` setting.
    let selectedLocale: String
    var onWillToggle: () -> Void = {}
    /// Persists a language chosen from the menu.
    let onSelectLocale: (String) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button {
            onWillToggle()
            dictation.toggle()
        } label: {
            Image(systemName: ACPComposerControlPresentation.micIconName(for: dictation.state))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(
                    dictation.state == .listening
                        ? ACPSelectChip.labelForeground(accent: theme.color("caution"), theme: theme)
                        : theme.color("fg-muted")
                )
                .frame(width: 28, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            dictation.state == .listening
                                ? theme.color("caution").opacity(0.55)
                                : theme.color("bg-3").opacity(0.7)
                        )
                )
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.color("line"), lineWidth: 0.75))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dictate")
        .help(ACPComposerControlPresentation.micHelp(for: dictation.state))
        .contextMenu {
            ForEach(ACPComposerControlPresentation.dictationMenuItems(
                installed: installedLocales,
                selected: selectedLocale
            )) { item in
                Button {
                    // Stop first, so a session never keeps running under a
                    // language the menu no longer shows as current.
                    dictation.stop()
                    onSelectLocale(item.localeIdentifier)
                } label: {
                    // A checkmark prefix rather than a Toggle: these are
                    // mutually exclusive and Toggle rows in a context menu
                    // read as independently switchable.
                    Text(item.isSelected ? "✓ \(item.title)" : item.title)
                }
            }
        }
    }
}
