import Foundation
import Observation

/// State + logic for the run script palette (⌘R). Scripts are loaded once
/// per open (`load`) — rescan-on-open, no watchers.
@Observable
@MainActor
final class RunScriptPaletteModel {
    enum Mode {
        case run
        case edit
    }

    enum Row: Equatable {
        case header(String)
        case script(RunScript)
        case newRepoScript
        case newGlobalScript

        var isSelectable: Bool {
            if case .header = self { return false }
            return true
        }
    }

    private(set) var mode: Mode = .run
    var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            snapSelectionToFirstSelectable()
            scrollToSelectionTick &+= 1
        }
    }
    private(set) var selectedIndex = 0
    private(set) var scrollToSelectionTick = 0
    private(set) var scripts: [RunScript] = []

    func prepareForOpen(mode: Mode) {
        reset()
        self.mode = mode
    }

    func load(environment env: RunScriptPaletteEnvironment) {
        scripts = env.scripts()
        snapSelectionToFirstSelectable()
    }

    func reset() {
        mode = .run
        query = ""
        selectedIndex = 0
        scrollToSelectionTick = 0
        scripts = []
    }

    func rows() -> [Row] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var rows: [Row] = []
        for scope in RunScriptScope.allCases {
            let pool = filtered(scripts.filter { $0.scope == scope }, query: trimmed)
            if !pool.isEmpty {
                rows.append(.header(scope.sectionTitle))
                rows.append(contentsOf: pool.map(Row.script))
            }
        }
        if trimmed.isEmpty {
            rows.append(.newRepoScript)
            rows.append(.newGlobalScript)
        }
        return rows
    }

    private func filtered(_ pool: [RunScript], query: String) -> [RunScript] {
        guard !query.isEmpty else { return pool }
        return pool
            .compactMap { script -> (RunScript, Double)? in
                if let r = FuzzyMatch.score(query: query, target: script.displayName) {
                    return (script, r.score)
                }
                if let r = FuzzyMatch.score(query: query, target: script.fileName) {
                    return (script, r.score - 1)
                }
                return nil
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    func moveSelection(step: Int) {
        let selectable = rows().map(\.isSelectable)
        var i = selectedIndex + step
        while i >= 0 && i < selectable.count {
            if selectable[i] {
                selectedIndex = i
                scrollToSelectionTick &+= 1
                return
            }
            i += step
        }
    }

    func setSelectedIndex(_ index: Int) {
        selectedIndex = index
    }

    func selectedScript() -> RunScript? {
        let rows = rows()
        guard rows.indices.contains(selectedIndex),
              case .script(let script) = rows[selectedIndex] else { return nil }
        return script
    }

    /// Enter: run/focus or edit a script depending on mode, or create a new one from the trailing rows.
    func activateSelection(environment env: RunScriptPaletteEnvironment) {
        let rows = rows()
        guard rows.indices.contains(selectedIndex) else { return }
        switch rows[selectedIndex] {
        case .script(let script):
            switch mode {
            case .run:
                env.run(script)
            case .edit:
                env.edit(script)
            }
        case .newRepoScript:      env.newScript(.repo)
        case .newGlobalScript:    env.newScript(.global)
        case .header:             break
        }
    }

    /// Cmd+Enter: restart the selected script.
    func restartSelection(environment env: RunScriptPaletteEnvironment) {
        guard let script = selectedScript() else { return }
        env.restart(script)
    }

    /// Cmd+E: open the selected script in the editor.
    func editSelection(environment env: RunScriptPaletteEnvironment) {
        guard let script = selectedScript() else { return }
        env.edit(script)
    }

    private func snapSelectionToFirstSelectable() {
        let selectable = rows().map(\.isSelectable)
        selectedIndex = selectable.firstIndex(of: true) ?? 0
    }
}
