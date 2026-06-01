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
    static var spacesFile: URL { appSupportRoot.appendingPathComponent("spaces.json") }
    static var tabsDir: URL { appSupportRoot.appendingPathComponent("tabs", isDirectory: true) }

    static func ensureDirectoryExists(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

extension Paths {
    static func tabsFile(forWorktreeId id: String) -> URL {
        tabsDir.appendingPathComponent("\(id).json")
    }
}

extension Paths {
    static var buffersRoot: URL { appSupportRoot.appendingPathComponent("buffers", isDirectory: true) }

    static func buffersDir(forWorktreeId id: String) -> URL {
        buffersRoot.appendingPathComponent(id, isDirectory: true)
    }
}

extension Paths {
    static var acpSessionsRoot: URL { appSupportRoot.appendingPathComponent("acp-sessions", isDirectory: true) }

    static func acpSessionsDB(forWorktreeId id: String) -> URL {
        acpSessionsRoot.appendingPathComponent("\(id).sqlite")
    }
}

extension Paths {
    static var acpAdapterUpdatesFile: URL {
        appSupportRoot.appendingPathComponent("acp-adapter-updates.json")
    }
}

extension Paths {
    static var acpAttachmentsRoot: URL { appSupportRoot.appendingPathComponent("acp-attachments", isDirectory: true) }

    static func acpAttachmentsDir(forWorktreeId id: String) -> URL {
        acpAttachmentsRoot.appendingPathComponent(id, isDirectory: true)
    }
}
