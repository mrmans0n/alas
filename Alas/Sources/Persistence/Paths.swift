import CryptoKit
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
    static var workspacesFile: URL { appSupportRoot.appendingPathComponent("workspaces.json") }
    static var attentionEventsFile: URL { appSupportRoot.appendingPathComponent("attention-events.json") }
    static var tabsDir: URL { appSupportRoot.appendingPathComponent("tabs", isDirectory: true) }
    static var checkpointsRoot: URL { appSupportRoot.appendingPathComponent("checkpoints", isDirectory: true) }

    static func checkpointsDirectory(lineageID: String) throws -> URL {
        guard let uuid = UUID(uuidString: lineageID),
              lineageID == lineageID.lowercased(),
              uuid.uuidString.lowercased() == lineageID
        else { throw CheckpointPathsError.invalidLineageID }
        return checkpointsRoot.appendingPathComponent(lineageID, isDirectory: true)
    }

    static func ensureDirectoryExists(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

enum CheckpointPathsError: Error, Equatable, Sendable {
    case invalidLineageID
}

extension Paths {
    static func tabsFile(for owner: SessionOwnerID) -> URL {
        tabsFile(forWorktreeId: owner.tabStorageKey)
    }

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

    /// Legacy worktree owners retain the historical path; project worktrees
    /// use a bounded, namespaced filename, and checkouts keep their own name.
    static func acpSessionsDB(for owner: SessionOwnerID) -> URL {
        if case .projectWorktree(let projectId, let worktreeId) = owner {
            let identity = Data("\(projectId.utf8.count):\(projectId)\(worktreeId)".utf8)
            let digest = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
            return acpSessionsDB(forWorktreeId: "project-worktree-v2--\(digest)")
        }
        return acpSessionsDB(forWorktreeId: owner.storageKey)
    }

    /// Pre-digest project-scoped databases remain readable after upgrading.
    static func previousProjectScopedACPSessionsDB(for owner: SessionOwnerID) -> URL? {
        guard case .projectWorktree = owner else { return nil }
        return acpSessionsDB(forWorktreeId: owner.storageKey)
    }

    static func acpSessionsDB(forProjectId projectId: String, worktreeId: String) -> URL {
        acpSessionsDB(for: .projectWorktree(projectId: projectId, worktreeId: worktreeId))
    }

    static var acpOrchestrationDB: URL {
        appSupportRoot.appendingPathComponent("acp-orchestration.sqlite")
    }
}

extension Paths {
    static var runHistoryDB: URL {
        appSupportRoot.appendingPathComponent("run-history.sqlite")
    }
}

extension Paths {
    static var acpAdapterUpdatesFile: URL {
        appSupportRoot.appendingPathComponent("acp-adapter-updates.json")
    }
}

extension Paths {
    static var remoteDevicesFile: URL {
        appSupportRoot.appendingPathComponent("remote-devices.json")
    }
}

extension Paths {
    static var remotePeersFile: URL {
        appSupportRoot.appendingPathComponent("remote-peers.json")
    }

    /// Fallback home for remote credentials on builds the data protection
    /// keychain refuses (see `RemoteKeychainSecretStore`). Owner-only.
    static var remoteSecretsDir: URL {
        appSupportRoot.appendingPathComponent("remote-secrets", isDirectory: true)
    }
}

extension Paths {
    static var reviewDraftCommentsFile: URL {
        appSupportRoot.appendingPathComponent("review-draft-comments.json")
    }

    static var reviewSessionsFile: URL {
        appSupportRoot.appendingPathComponent("review-sessions.json")
    }
}

extension Paths {
    static var acpAttachmentsRoot: URL { appSupportRoot.appendingPathComponent("acp-attachments", isDirectory: true) }

    static func acpAttachmentsDir(forWorktreeId id: String) -> URL {
        acpAttachmentsRoot.appendingPathComponent(id, isDirectory: true)
    }
}

extension Paths {
    static var projectIconsRoot: URL { appSupportRoot.appendingPathComponent("project-icons", isDirectory: true) }

    static func projectIconsDir(forProjectId id: String) -> URL {
        projectIconsRoot.appendingPathComponent(id, isDirectory: true)
    }
}

extension Paths {
    static var runScriptsGlobalDir: URL {
        appSupportRoot.appendingPathComponent("run-scripts/global", isDirectory: true)
    }
}
