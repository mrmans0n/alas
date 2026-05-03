import Foundation

enum Paths {
    static let appSupportRoot: URL = {
        let base = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent("Alas", isDirectory: true)
    }()

    static var appConfigFile: URL { appSupportRoot.appendingPathComponent("app.json") }
    static var projectsFile: URL { appSupportRoot.appendingPathComponent("projects.json") }
    static var tabsDir: URL { appSupportRoot.appendingPathComponent("tabs", isDirectory: true) }
    static var hookDir: URL { appSupportRoot.appendingPathComponent("hooks", isDirectory: true) }

    static func ensureDirectoryExists(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
