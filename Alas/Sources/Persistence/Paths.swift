import CryptoKit
import Darwin
import Foundation

/// Which on-disk profile this process runs against.
///
/// By default Alas uses `~/Library/Application Support/Alas` and the shared
/// per-user socket locations. Setting `ALAS_APP_SUPPORT_DIR` to an absolute
/// path launches an *isolated* profile instead — meant for running a second
/// dev instance next to the everyday one (`open -n Alas.app --env
/// ALAS_APP_SUPPORT_DIR=/tmp/alas-e2e`). An isolated profile keeps its state
/// under that directory and its sockets (hook server, zmx, ACP brokers) under
/// a private runtime directory keyed by the profile path, so it never sees,
/// adopts, or reaps anything belonging to another instance.
struct AlasProfile: Equatable, Sendable {
    static let environmentKey = "ALAS_APP_SUPPORT_DIR"

    enum Resolution: Equatable, Sendable {
        case standard
        case isolated(URL)
        case invalid(String)
    }

    /// The app-support override, or nil for the standard profile.
    let appSupportOverride: URL?
    /// Private directory for sockets: `/tmp/alas-<uid>-<hash>`. Kept short on
    /// purpose, since a profile path can be long and `sun_path` holds only 104
    /// bytes. Nil for the standard profile, which keeps its historical paths.
    let runtimeDirectory: URL?

    var isIsolated: Bool { appSupportOverride != nil }

    static let current: AlasProfile = {
        switch resolve(environment: ProcessInfo.processInfo.environment) {
        case .standard:
            return AlasProfile(appSupportOverride: nil, runtimeDirectory: nil)
        case .isolated(let root):
            let runtime = runtimeDirectory(for: root, uid: getuid())
            // Fail closed: an isolated instance that silently fell back to the
            // shared locations would do exactly what the override exists to
            // prevent. Both directories may sit in world-writable `/tmp`, so
            // each must be a real, owner-only directory before anything is
            // written into it.
            guard preparePrivateDirectory(root, ownerUid: getuid()) else {
                fatalError("\(environmentKey): \(root.path) must be a directory owned by this user and closed to others")
            }
            guard AgentHookSocketServer.prepareSocketDirectory(runtime.path, ownerUid: getuid()) else {
                fatalError("\(environmentKey): cannot create a private runtime directory at \(runtime.path)")
            }
            return AlasProfile(appSupportOverride: root, runtimeDirectory: runtime)
        case .invalid(let value):
            fatalError("\(environmentKey) must be an absolute path, got \"\(value)\"")
        }
    }()

    /// Pure resolution of the override. Unset or blank means the standard
    /// profile; anything that is not an absolute path (after `~` expansion)
    /// is invalid rather than silently ignored, because ignoring it would put
    /// a would-be isolated instance on the shared profile.
    static func resolve(environment: [String: String]) -> Resolution {
        guard let raw = environment[environmentKey] else { return .standard }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .standard }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return .invalid(raw) }
        return .isolated(URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL)
    }

    /// Creates `url` (and missing parents) owner-only, or tightens an existing
    /// directory this user owns to `0700`. Refuses a symlink, a non-directory,
    /// or a directory owned by someone else.
    static func preparePrivateDirectory(_ url: URL, ownerUid: uid_t) -> Bool {
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        var st = Darwin.stat()
        guard Darwin.lstat(url.path, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFDIR,
              st.st_uid == ownerUid
        else { return false }
        return (st.st_mode & 0o077) == 0 || chmod(url.path, 0o700) == 0
    }

    /// Preferences this app writes (update-check timestamp, GG undo markers,
    /// SSH acceleration host lists). An isolated profile uses its own suite so
    /// it cannot suppress the main instance's update check or change its
    /// persisted state. System preferences (`AppleInterfaceStyle`, …) are still
    /// read from `.standard`.
    static var userDefaults: UserDefaults {
        guard let runtime = current.runtimeDirectory,
              let suite = UserDefaults(suiteName: "io.nlopez.alas.profile.\(runtime.lastPathComponent)")
        else { return .standard }
        return suite
    }

    static func runtimeDirectory(for appSupportRoot: URL, uid: uid_t) -> URL {
        let digest = SHA256.hash(data: Data(appSupportRoot.standardizedFileURL.path.utf8))
        let hash = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return URL(fileURLWithPath: "/tmp/alas-\(uid)-\(hash)", isDirectory: true)
    }
}

enum Paths {
    static let appSupportRoot: URL = {
        if let override = AlasProfile.current.appSupportOverride {
            return override
        }
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
        tabsFile(forWorktreeId: owner.storageKey)
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

    /// Worktree owners deliberately retain the historical filename while a
    /// checkout gets its own namespaced database. This keeps existing ACP
    /// histories intact and prevents equal paths on separate hosts colliding.
    static func acpSessionsDB(for owner: SessionOwnerID) -> URL {
        acpSessionsDB(forWorktreeId: owner.storageKey)
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

    static var pendingReviewsDir: URL {
        appSupportRoot.appendingPathComponent("pending-reviews", isDirectory: true)
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

extension Paths {
    static var localTextModelsRoot: URL {
        appSupportRoot.appendingPathComponent("Models/NextPromptSuggestions", isDirectory: true)
    }
}
