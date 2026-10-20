import SwiftUI

/// The composer's push-to-talk button, with language and microphone menus
/// on right-click. Shared by the local and peer composers.
struct ACPDictationMicButton: View {
    @ObservedObject var dictation: ACPDictationService
    let preferences: ACPDictationPreferences
    var onWillToggle: () -> Void = {}
    /// Persists a language or microphone chosen from the menu.
    let onChangePreferences: (ACPDictationPreferences) -> Void
    @Environment(\.theme) private var theme
    /// Languages ready to use without a download.
    @State private var installedLocales: [String] = []
    @State private var microphones: [ACPAudioInputDevice] = []

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
            Section("Language") {
                menuEntries(ACPComposerControlPresentation.languageMenuItems(
                    installed: installedLocales,
                    selected: preferences.localeIdentifier
                )) { identifier in
                    var updated = preferences
                    updated.localeIdentifier = identifier
                    return updated
                }
            }
            Section("Microphone") {
                menuEntries(ACPComposerControlPresentation.microphoneMenuItems(
                    available: microphones,
                    selected: preferences.microphone
                )) { identifier in
                    var updated = preferences
                    updated.microphone = ACPComposerControlPresentation.microphone(
                        forMenuIdentifier: identifier,
                        available: microphones,
                        selected: preferences.microphone
                    )
                    return updated
                }
            }
        }
        .task { installedLocales = await dictation.installedLocaleIdentifiers() }
        .task {
            for await devices in ACPAudioInputDevices.updates() { microphones = devices }
        }
    }

    private func menuEntries(
        _ items: [ACPDictationMenuItem],
        applying choice: @escaping (String) -> ACPDictationPreferences
    ) -> some View {
        ForEach(items) { item in
            Button {
                // Stop first, so a session never keeps running under a
                // choice the menu no longer shows as current.
                dictation.stop()
                onChangePreferences(choice(item.identifier))
            } label: {
                // A checkmark prefix rather than a Toggle: these are
                // mutually exclusive and Toggle rows in a context menu
                // read as independently switchable.
                Text(item.isSelected ? "✓ \(item.title)" : item.title)
            }
        }
    }
}
