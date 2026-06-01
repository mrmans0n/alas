import Foundation

/// How this copy of Alas was installed, used to tailor the update action.
enum InstallSource: Equatable {
    case homebrew
    case direct

    /// Detects a Homebrew install by probing for the cask's Caskroom directory.
    /// PATH-independent (does not shell out to `brew`), so it works for GUI launches.
    static func detect(
        fileManager: FileManager = .default,
        caskroomPaths: [String] = [
            "/opt/homebrew/Caskroom/alas",
            "/usr/local/Caskroom/alas",
        ]
    ) -> InstallSource {
        for path in caskroomPaths {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                return .homebrew
            }
        }
        return .direct
    }
}
