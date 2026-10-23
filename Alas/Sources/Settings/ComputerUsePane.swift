import AlasCore
import AppKit
import SwiftUI

struct ComputerUsePane: View {
    @Bindable var state: AppState
    @Environment(\.theme) var theme
    @State private var granted: Set<ComputerUsePermission>
    @State private var isAdHoc: Bool
    @State private var requestedScreenRecording = AppRelaunch.screenRecordingRequested
    @State private var isWatchingInput = ComputerUseUserInput.isWatching

    init(state: AppState) {
        self.state = state
        _granted = State(initialValue: ComputerUsePlatform.shared.grantedPermissions())
        _isAdHoc = State(initialValue: ComputerUsePlatform.shared.isAdHocSigned())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Computer Use").font(.system(size: 18, weight: .semibold))
                Text("Let agents see and operate other apps on this Mac. They work in the background and never move your cursor.")
                    .font(.system(size: 12.5)).foregroundColor(theme.color("fg-dim"))
                    .padding(.bottom, 12)

                SettingsGroup(title: "Computer Use") {
                    SettingsRow(
                        name: "Let agents use apps on this Mac",
                        desc: "Agents can still only touch apps you approve."
                    ) {
                        AlasToggle(on: state.bind(\.computerUse.enabled))
                    }
                }

                SettingsGroup(title: "macOS permissions") {
                    ForEach(ComputerUsePermission.allCases, id: \.self) { permission in
                        permissionRow(permission)
                    }
                    inputWatchingRow
                }

                SettingsGroup(title: "Always allowed apps") {
                    Text("If Codex also has OpenAI's Computer Use plugin turned on, agents there see both sets of tools. Approving an app lets agents click and type in it, not just see it. For Electron and Chrome-based apps, Alas turns on their accessibility support, which can make them use a bit more memory.")
                        .font(.system(size: 12))
                        .foregroundColor(theme.color("fg-dim"))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 8)
                    let bundleIDs = state.config.computerUse.alwaysAllowedApps
                    if bundleIDs.isEmpty {
                        Text("No apps yet. Choose \"Always allow\" when an agent asks.")
                            .font(.system(size: 12.5))
                            .foregroundColor(theme.color("fg-dim"))
                    } else {
                        ForEach(bundleIDs, id: \.self) { bundleID in
                            SettingsRow(name: bundleID) {
                                AlasButton(title: "Remove") {
                                    state.config.computerUse.alwaysAllowedApps.removeAll { $0 == bundleID }
                                    state.saveConfig()
                                }
                            }
                        }
                    }
                }

                if isAdHoc {
                    SettingsGroup(title: "Development build") {
                        Text("This build is ad-hoc signed, so macOS forgets these permissions every time it is rebuilt. See \"Local signing for dev builds\" in AGENTS.md.")
                            .font(.system(size: 12))
                            .foregroundColor(theme.color("fg-dim"))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    @ViewBuilder
    private func permissionRow(_ permission: ComputerUsePermission) -> some View {
        let isGranted = granted.contains(permission)
        let needsRelaunch = permission == .screenRecording && !isGranted && requestedScreenRecording
        SettingsRow(
            name: permission.displayName,
            desc: description(for: permission),
            detail: {
                if needsRelaunch {
                    Text("macOS applies Screen Recording after \(AppRelaunch.appName) restarts.")
                        .font(.system(size: 11.5))
                        .foregroundColor(theme.color("fg-dim"))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        ) {
            if isGranted {
                Text("Granted")
                    .font(.system(size: 12.5))
                    .foregroundColor(theme.color("fg-dim"))
            } else if needsRelaunch {
                AlasButton(title: "Relaunch \(AppRelaunch.appName)") {
                    AppRelaunch.relaunch()
                }
            } else {
                AlasButton(title: "Grant…") {
                    ComputerUsePlatform.shared.request(permission)
                    URLOpening.shared.open(permission.settingsURL)
                    if permission == .screenRecording {
                        AppRelaunch.screenRecordingRequested = true
                        requestedScreenRecording = true
                    }
                }
            }
        }
    }

    /// Whether Alas sees the user's own input, which holds agents back while the user works.
    private var inputWatchingRow: some View {
        SettingsRow(
            name: "Input watching",
            desc: "Lets Alas pause agents while you type or use the mouse in the app they work in."
        ) {
            if isWatchingInput {
                Text("On")
                    .font(.system(size: 12.5))
                    .foregroundColor(theme.color("fg-dim"))
            } else {
                HStack(spacing: 8) {
                    Text("Off — Alas can't tell when you're using an app")
                        .font(.system(size: 12.5))
                        .foregroundColor(theme.color("fg-dim"))
                    AlasButton(title: "Grant…") {
                        ComputerUseUserInput.requestListenAccess()
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                            URLOpening.shared.open(url)
                        }
                    }
                }
            }
        }
    }

    private func description(for permission: ComputerUsePermission) -> String {
        switch permission {
        case .screenRecording:
            return "Lets agents take screenshots of app windows. macOS shows the purple recording indicator while they look."
        case .accessibility:
            return "Lets agents read an app's controls and click or type in it without moving your cursor."
        }
    }

    private func refresh() {
        granted = ComputerUsePlatform.shared.grantedPermissions()
        isWatchingInput = ComputerUseUserInput.isWatching
    }
}
