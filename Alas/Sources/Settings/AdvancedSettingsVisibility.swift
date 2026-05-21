import Foundation

struct AdvancedSettingsVisibility {
    static var debugFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".alas", isDirectory: true)
            .appendingPathComponent(".debug")
    }

    static func isEnabled(
        fileManager: FileManager = .default,
        debugFileURL: URL = Self.debugFileURL
    ) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: debugFileURL.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }
}
