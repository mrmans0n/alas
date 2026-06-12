import SwiftUI

struct DiffPreferenceBindings {
    let appState: AppState

    var layoutMode: Binding<DiffLayoutMode> {
        Binding(
            get: { appState.config.changes.diffLayoutMode },
            set: { newValue in
                guard appState.config.changes.diffLayoutMode != newValue else { return }
                appState.config.changes.diffLayoutMode = newValue
                appState.saveConfig()
            }
        )
    }

    var wrapLines: Binding<Bool> {
        Binding(
            get: { appState.config.changes.diffWrapLines },
            set: { newValue in
                guard appState.config.changes.diffWrapLines != newValue else { return }
                appState.config.changes.diffWrapLines = newValue
                appState.saveConfig()
            }
        )
    }

    var showWhitespace: Binding<Bool> {
        Binding(
            get: { appState.config.changes.diffShowWhitespace },
            set: { newValue in
                guard appState.config.changes.diffShowWhitespace != newValue else { return }
                appState.config.changes.diffShowWhitespace = newValue
                appState.saveConfig()
            }
        )
    }
}
