import SwiftUI

struct RootView: View {
    @Bindable var state: AppState

    var body: some View {
        ThreePaneLayout(
            sidebarWidth: Binding(
                get: { state.config.sidebarWidth },
                set: { state.config.sidebarWidth = $0 }
            ),
            rightWidth: Binding(
                get: { state.config.rightPaneWidth },
                set: { state.config.rightPaneWidth = $0 }
            ),
            rightVisible: state.config.rightPaneVisible,
            onWidthsChanged: { state.saveConfig() },
            sidebar: { SidebarPlaceholder() },
            center: { CenterPlaceholder() },
            right: { RightPlaceholder() }
        )
        .environment(\.theme, state.themeStore.current)
        .background(WindowConfigurator())
        .frame(minWidth: 900, minHeight: 600)
        .ignoresSafeArea()
    }
}
