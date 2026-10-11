import Foundation

/// External reads/side effects for the run script palette, injected so the
/// model is unit-testable (same pattern as `ReviewTargetPaletteEnvironment`).
public struct RunScriptPaletteEnvironment {
    public var scripts: () -> [RunScript]
    public var isRunning: (RunScript) -> Bool
    /// `nil` console runs with the script's `alas-console` default.
    public var run: (RunScript, RunScriptConsole?) -> Void
    public var restart: (RunScript) -> Void
    public var edit: (RunScript) -> Void
    public var newScript: (RunScriptScope) -> Void

    public init(scripts: @escaping () -> [RunScript], isRunning: @escaping (RunScript) -> Bool, run: @escaping (RunScript, RunScriptConsole?) -> Void, restart: @escaping (RunScript) -> Void, edit: @escaping (RunScript) -> Void, newScript: @escaping (RunScriptScope) -> Void) {
        self.scripts = scripts
        self.isRunning = isRunning
        self.run = run
        self.restart = restart
        self.edit = edit
        self.newScript = newScript
    }
}
