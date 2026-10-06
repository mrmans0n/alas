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
        case .isolated(let requested):
            // Checked before anything touches `requested`: preparing it would
            // tighten the everyday profile's permissions, and using it would
            // share its files while splitting sockets and preferences.
            guard !isSameDirectory(requested, Paths.standardAppSupportRoot) else {
                fatalError("\(environmentKey) names the standard profile at \(Paths.standardAppSupportRoot.path)")
            }
            // Fail closed: an isolated instance that silently fell back to the
            // shared locations would do exactly what the override exists to
            // prevent. Both directories may sit in world-writable `/tmp`, so
            // each must be a real, owner-only directory before anything is
            // written into it.
            guard preparePrivateDirectory(requested, ownerUid: getuid()),
                  let root = canonicalDirectory(requested)
            else {
                fatalError("\(environmentKey): \(requested.path) must be a directory owned by this user and closed to others")
            }
            let runtime = runtimeDirectory(for: root, uid: getuid())
            guard AgentHookSocketServer.prepareSocketDirectory(runtime.path, ownerUid: getuid()) else {
                fatalError("\(environmentKey): runtime directory \(runtime.path) must be a directory owned by this user, not writable by group or others, that Alas can set to 0700; remove it so Alas recreates it")
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
    /// a directory owned by someone else, or one group or others could write.
    static func preparePrivateDirectory(_ url: URL, ownerUid: uid_t) -> Bool {
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        return AgentHookSocketServer.prepareSocketDirectory(url.path, ownerUid: ownerUid)
    }

    /// The filesystem's own spelling of an existing directory: symlinks in any
    /// component resolved and letter case as stored. The runtime directory,
    /// preference suite, and Keychain service all derive from this path, so
    /// two spellings of one profile (`/tmp/x` vs `/private/tmp/X`) must agree.
    static func canonicalDirectory(_ url: URL) -> URL? {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) == 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
    }

    /// Whether two paths name one directory, however they are spelled. Either
    /// may not exist yet (the standard root is only created on first launch),
    /// so each is canonicalized through its deepest existing ancestor.
    /// Components that do not exist yet are compared case-insensitively, as
    /// the default macOS volume would treat them once created; erring toward
    /// "same" only ever refuses a launch.
    static func isSameDirectory(_ lhs: URL, _ rhs: URL) -> Bool {
        canonicalPath(lhs).caseInsensitiveCompare(canonicalPath(rhs)) == .orderedSame
    }

    private static func canonicalPath(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var missing: [String] = []
        while canonicalDirectory(existing) == nil, existing.path != "/" {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        let base = canonicalDirectory(existing) ?? existing
        return missing.reduce(base) { $0.appendingPathComponent($1) }.path
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
        AlasProfile.current.appSupportOverride ?? standardAppSupportRoot
    }()

    /// `~/Library/Application Support/Alas`: the everyday profile's root.
    static var standardAppSupportRoot: URL {
        let base = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent("Alas", isDirectory: true)
    }

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

    static var usageHistoryDB: URL {
        appSupportRoot.appendingPathComponent("usage-history.sqlite")
    }
}

extension Paths {
    static var acpAdapterUpdatesFile: URL {
        appSupportRoot.appendingPathComponent("acp-adapter-updates.json")
    }

    /// Install root for agents installed from the ACP registry, one
    /// directory per registry id.
    static var acpRegistryAgentsDirectory: URL {
        appSupportRoot.appendingPathComponent("acp-agents", isDirectory: true)
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
