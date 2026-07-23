import Foundation

/// External reads/side effects for the run script palette, injected so the
/// model is unit-testable (same pattern as `ReviewTargetPaletteEnvironment`).
struct RunScriptPaletteEnvironment {
    var scripts: () -> [RunScript]
    var isRunning: (RunScript) -> Bool
    var run: (RunScript) -> Void
    var restart: (RunScript) -> Void
    var edit: (RunScript) -> Void
    var newScript: (RunScriptScope) -> Void
}
