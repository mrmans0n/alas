import AlasCore
import AppKit
import SwiftUI

struct ComputerUsePane: View {
    @Bindable var state: AppState
    @Environment(\.theme) var theme
    @State private var granted: Set<ComputerUsePermission>
    @State private var isAdHoc: Bool
    @State private var requestedScreenRecording = AppRelaunch.screenRecordingRequested

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
    }
}
