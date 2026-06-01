import Foundation

/// How this copy of Alas was installed, used to tailor the update action.
enum InstallSource: Equatable {
    case homebrew
    case direct

    /// Detects a Homebrew install by checking that the *running* app is the copy
    /// the cask installed: it runs from the cask's app location
    /// (`/Applications/Alas.app`) AND the cask's Caskroom directory exists.
    /// PATH-independent (no `brew` subprocess), so it works for GUI launches.
    ///
    /// Requiring the running bundle to match the install location avoids
    /// mislabeling a separately-downloaded DMG copy as Homebrew just because a
    /// cask exists elsewhere on the machine — which would otherwise suggest
    /// `brew upgrade`, updating the cask copy rather than the running app.
    static func detect(
        bundlePath: String = Bundle.main.bundlePath,
        fileManager: FileManager = .default,
        appInstallPath: String = "/Applications/Alas.app",
        caskroomPaths: [String] = [
            "/opt/homebrew/Caskroom/alas",
            "/usr/local/Caskroom/alas",
        ]
    ) -> InstallSource {
        let running = URL(fileURLWithPath: bundlePath).standardizedFileURL.path
        let installed = URL(fileURLWithPath: appInstallPath).standardizedFileURL.path
        guard running == installed else { return .direct }

        for path in caskroomPaths {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                return .homebrew
            }
        }
        return .direct
    }
}
