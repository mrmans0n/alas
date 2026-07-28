import SwiftUI

struct DiffPreferenceBindings {
    let appState: AppState
    private let wrapLinesStorage: Binding<Bool>
    private let showWhitespaceStorage: Binding<Bool>

    init(
        appState: AppState,
        wrapLines: Binding<Bool>,
        showWhitespace: Binding<Bool>
    ) {
        self.appState = appState
        self.wrapLinesStorage = wrapLines
        self.showWhitespaceStorage = showWhitespace
    }

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
        wrapLinesStorage
    }

    var showWhitespace: Binding<Bool> {
        showWhitespaceStorage
    }
}
