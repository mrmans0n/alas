import AlasCore
import Foundation
import SQLite3

/// Prepares a stopped macOS guest's mounted Data volume for unattended use:
/// the `alas` admin user, its home, Setup Assistant marked done, auto-login,
/// sshd on (for the SSH finishing step), no sleep or lock, and the helper's
/// Accessibility and Screen Recording grants.
///
/// It never writes the helper app or a LaunchAgent: every host-written file
/// carries `com.apple.provenance`, and launchd skips such agents, so those are
/// installed from inside the guest.
///
/// The file handling (edit existing plists in place, owner-execute on dslocal
/// directories, ByHost discovery) is ported from trycua/cua `libs/lume`
/// `src/Unattended/MacOSOfflineSetupPatcher.swift` (MIT). Every write is
/// idempotent: patching an already-patched volume leaves its files unchanged
/// and replaces the TCC rows.
enum VMGuestPatcher {
    enum PatchError: LocalizedError, Equatable {
        case missingTCCDatabase(String)
        case missingDirectoryServices(String)
        case uidTaken(uid: Int, by: String)
        case invalidPlist(String)
        case tcc(String)

        var errorDescription: String? {
            switch self {
            case .missingTCCDatabase(let path): "The guest has no TCC database yet (\(path))"
            case .missingDirectoryServices(let path): "The guest has no local directory node (\(path))"
            case let .uidTaken(uid, by): "UID \(uid) already belongs to \(by)"
            case .invalidPlist(let path): "Not a property list: \(path)"
            case .tcc(let message): "Could not grant the helper's permissions: \(message)"
            }
        }
    }

    static let tccDatabasePath = "Library/Application Support/com.apple.TCC/TCC.db"
    private static let dslocalPath = "private/var/db/dslocal/nodes/Default"

    static func patch(
        dataVolume: URL,
        systemVersion: (product: String, build: String),
        helperCodeRequirement: Data,
        account: VMGuestAccount
    ) throws {
        let volume = Volume(root: dataVolume)
        let tccDatabase = volume.url(tccDatabasePath)
        guard volume.exists(tccDatabase) else { throw PatchError.missingTCCDatabase(tccDatabase.path) }
        let dslocal = volume.url(dslocalPath)
        guard volume.exists(dslocal) else { throw PatchError.missingDirectoryServices(dslocal.path) }

        // The host sees these as mode 600/700; without the search bit nothing
        // inside can be read or written.
        for directory in ["", "/users", "/groups"] {
            try volume.ensureDirectoryExecutable(volume.url(dslocalPath + directory))
        }
        try ensureUIDAvailable(account, volume: volume)

        try grant(VMGuestProvisioning.TCCGrant.helper(csreq: helperCodeRequirement), in: tccDatabase)
        let generatedUID = try writeUserRecord(account, volume: volume)
        try addToGroups(account, generatedUID: generatedUID, volume: volume)
        try writeHome(account, systemVersion: systemVersion, volume: volume)
        try markSetupDone(systemVersion: systemVersion, volume: volume)
        try configureAutoLogin(account, volume: volume)
        try enableSSH(volume: volume)
        try configurePowerAndLock(account, volume: volume)
    }

    // MARK: - Directory services

    private static func writeUserRecord(_ account: VMGuestAccount, volume: Volume) throws -> UUID {
        let users = volume.url("\(dslocalPath)/users")
        let recordURL = users.appendingPathComponent("\(account.shortName).plist")
        let existing = try volume.readPlistIfPresent(recordURL)

        let generatedUID = (existing["generateduid"] as? [String])?.first.flatMap(UUID.init(uuidString:)) ?? UUID()
        let shadowHash = try existingShadowHash(in: existing, verifying: account.password)
            ?? VMGuestProvisioning.shadowHashData(password: account.password, salt: VMGuestProvisioning.randomSalt())
        let record = existing.merging(
            VMGuestProvisioning.userRecord(account, generatedUID: generatedUID, shadowHash: shadowHash)
        ) { _, new in new }
        try volume.writePlist(record, to: recordURL, mode: 0o600)
        return generatedUID
    }

    /// The record's current `ShadowHashData` when it already verifies the
    /// password, so a re-patch keeps the record byte-identical.
    private static func existingShadowHash(in record: [String: Any], verifying password: String) throws -> Data? {
        guard let data = (record["ShadowHashData"] as? [Data])?.first,
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let pbkdf2 = (plist as? [String: Any])?["SALTED-SHA512-PBKDF2"] as? [String: Any],
              let salt = pbkdf2["salt"] as? Data, salt.count == VMGuestProvisioning.saltLength,
              let iterations = pbkdf2["iterations"] as? Int, iterations > 0,
              let entropy = pbkdf2["entropy"] as? Data
        else { return nil }
        let candidate = try VMGuestProvisioning.shadowHashData(password: password, salt: salt, iterations: iterations)
        let candidateEntropy = ((try PropertyListSerialization.propertyList(from: candidate, options: [], format: nil)
                as? [String: Any])?["SALTED-SHA512-PBKDF2"] as? [String: Any])?["entropy"] as? Data
        return candidateEntropy == entropy ? data : nil
    }

    /// Refuses a guest where another account already has the uid (a golden
    /// set up by hand has its own user at 501).
    private static func ensureUIDAvailable(_ account: VMGuestAccount, volume: Volume) throws {
        let users = volume.url("\(dslocalPath)/users")
        let records = (try? FileManager.default.contentsOfDirectory(at: users, includingPropertiesForKeys: nil)) ?? []
        for url in records where url.pathExtension == "plist" && url.deletingPathExtension().lastPathComponent != account.shortName {
            guard let record = try? volume.readPlist(url),
                  (record["uid"] as? [String])?.first == String(account.uid) else { continue }
            throw PatchError.uidTaken(uid: account.uid, by: url.deletingPathExtension().lastPathComponent)
        }
    }

    private static func addToGroups(_ account: VMGuestAccount, generatedUID: UUID, volume: Volume) throws {
        for name in ["admin", "staff"] {
            let url = volume.url("\(dslocalPath)/groups/\(name).plist")
            guard volume.exists(url) else { continue }
            let group = VMGuestProvisioning.groupMembershipEdit(
                groupPlist: try volume.readPlist(url), adding: account, generatedUID: generatedUID
            )
            try volume.writePlist(group, to: url, mode: nil)
        }
    }

    // MARK: - Home and Setup Assistant

    private static func writeHome(
        _ account: VMGuestAccount, systemVersion: (product: String, build: String), volume: Volume
    ) throws {
        let home = volume.url(account.homeDirectory)
        // LaunchAgents stays empty: the finishing step writes the agent from inside the guest.
        for directory in ["Library/Preferences/ByHost", "Library/LaunchAgents", "Desktop", "Documents", "Downloads"] {
            try volume.createDirectory(home.appendingPathComponent(directory))
        }
        try volume.setMode(0o755, of: home)
        try volume.write(
            Data(String(format: "0x%X:0x0:0x0\n", account.uid).utf8),
            to: home.appendingPathComponent(".CFUserTextEncoding"), mode: 0o644
        )
        try volume.writePlist(
            VMGuestProvisioning.setupAssistantPreferences(
                productVersion: systemVersion.product, buildVersion: systemVersion.build
            ),
            to: home.appendingPathComponent("Library/Preferences/com.apple.SetupAssistant.plist")
        )
    }

    private static func markSetupDone(systemVersion: (product: String, build: String), volume: Volume) throws {
        try volume.touch(volume.url("private/var/db/.AppleSetupDone"))
        try volume.writePlist(
            VMGuestProvisioning.setupAssistantPreferences(
                productVersion: systemVersion.product, buildVersion: systemVersion.build
            ),
            to: volume.url("Library/Preferences/com.apple.SetupAssistant.plist")
        )
    }

    private static func configureAutoLogin(_ account: VMGuestAccount, volume: Volume) throws {
        let loginwindow = volume.url("Library/Preferences/com.apple.loginwindow.plist")
        try volume.writePlist(
            VMGuestProvisioning.loginwindowPreferences(
                existing: try volume.readPlistIfPresent(loginwindow), autoLoginUser: account.shortName
            ),
            to: loginwindow
        )
        try volume.write(
            VMGuestProvisioning.kcpassword(account.password), to: volume.url("private/etc/kcpassword"), mode: 0o600
        )
    }

    private static func enableSSH(volume: Volume) throws {
        let disabled = volume.url("private/var/db/com.apple.xpc.launchd/disabled.plist")
        try volume.touch(disabled.deletingLastPathComponent().appendingPathComponent("disabled.migrated"))
        try volume.writePlist(
            VMGuestProvisioning.sshdEnabled(disabledPlist: try volume.readPlistIfPresent(disabled)),
            to: disabled, format: .xml
        )
    }

    // MARK: - Power and lock

    private static func configurePowerAndLock(_ account: VMGuestAccount, volume: Volume) throws {
        let preferences = volume.url("\(account.homeDirectory)/Library/Preferences")
        let userGlobal = preferences.appendingPathComponent(".GlobalPreferences.plist")
        try volume.writePlist(
            VMGuestProvisioning.userGlobalPreferences(existing: try volume.readPlistIfPresent(userGlobal)), to: userGlobal
        )
        let screensaver = preferences.appendingPathComponent("com.apple.screensaver.plist")
        try volume.writePlist(
            VMGuestProvisioning.userScreensaverPreferences(existing: try volume.readPlistIfPresent(screensaver)),
            to: screensaver
        )
        let byHost = preferences.appendingPathComponent("ByHost")
        let hostUUIDs = byHostUUIDs(in: byHost)
        for uuid in hostUUIDs {
            try volume.writePlist(
                VMGuestProvisioning.byHostScreensaverPreferences,
                to: byHost.appendingPathComponent("com.apple.screensaver.\(uuid).plist")
            )
        }

        let systemGlobal = volume.url("Library/Preferences/.GlobalPreferences.plist")
        try volume.writePlist(
            VMGuestProvisioning.systemGlobalPreferences(existing: try volume.readPlistIfPresent(systemGlobal)),
            to: systemGlobal
        )
        try volume.writePlist(
            VMGuestProvisioning.powerManagementPreferences,
            to: volume.url("Library/Preferences/com.apple.PowerManagement.plist")
        )
        for uuid in hostUUIDs {
            try volume.writePlist(
                VMGuestProvisioning.perHostPowerManagementPreferences,
                to: volume.url("Library/Preferences/com.apple.PowerManagement.\(uuid).plist")
            )
        }
    }

    /// The host UUIDs named by `ByHost/<domain>.<uuid>.plist` files.
    private static func byHostUUIDs(in directory: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let pattern = /([0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12})\.plist$/
        return Set(names.compactMap { name in (try? pattern.firstMatch(in: name)).map { String($0.1).uppercased() } })
            .sorted()
    }

    // MARK: - TCC

    /// Upserts the grants with the plain SQLite C API: opening read-write
    /// without `SQLITE_OPEN_CREATE` and without touching the journal mode.
    private static func grant(_ grants: [VMGuestProvisioning.TCCGrant], in database: URL) throws {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            throw PatchError.tcc(db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed")
        }
        func fail() -> PatchError { .tcc(String(cString: sqlite3_errmsg(db))) }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw fail() }
        do {
            for row in VMGuestProvisioning.tccUpsertSQL(grants) {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, row.sql, -1, &statement, nil) == SQLITE_OK else { throw fail() }
                defer { sqlite3_finalize(statement) }
                let bound = row.csreq.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, 1, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
                }
                guard bound == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw fail() }
            }
            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw fail() }
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

/// File operations relative to a mounted guest volume.
private struct Volume {
    let root: URL
    private var fm: FileManager { .default }

    /// `guestPath` is relative to the volume root; a leading `/` is ignored.
    func url(_ guestPath: String) -> URL {
        guestPath.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
    }

    func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

    func readPlistIfPresent(_ url: URL) throws -> [String: Any] {
        exists(url) ? try readPlist(url) : [:]
    }

    func readPlist(_ url: URL) throws -> [String: Any] {
        guard let plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: url), options: [], format: nil
        ) as? [String: Any] else { throw VMGuestPatcher.PatchError.invalidPlist(url.path) }
        return plist
    }

    /// Writes a plist unless the file already holds the same content in the
    /// same format. `mode` nil keeps an existing file's mode.
    func writePlist(
        _ plist: [String: Any], to url: URL, mode: Int? = 0o644,
        format: PropertyListSerialization.PropertyListFormat = .binary
    ) throws {
        if exists(url), let data = try? Data(contentsOf: url) {
            var existingFormat = PropertyListSerialization.PropertyListFormat.binary
            if let existing = try? PropertyListSerialization.propertyList(from: data, options: [], format: &existingFormat),
               existingFormat == format, (existing as? NSDictionary)?.isEqual(to: plist) == true {
                if let mode { try setMode(mode, of: url) }
                return
            }
        }
        try write(PropertyListSerialization.data(fromPropertyList: plist, format: format, options: 0), to: url, mode: mode)
    }

    /// Edits an existing file in place (open, truncate, write) and creates a
    /// missing one: launchd and loginwindow ignore atomically replaced files.
    func write(_ data: Data, to url: URL, mode: Int?) throws {
        guard exists(url) else {
            try createDirectory(url.deletingLastPathComponent())
            try data.write(to: url)
            try setMode(mode ?? 0o644, of: url)
            return
        }
        let current = try currentMode(of: url)
        let finalMode = mode ?? current
        let changed = try Data(contentsOf: url) != data
        if changed {
            try setMode(finalMode | 0o200, of: url)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: data)
        }
        if changed || current != finalMode { try setMode(finalMode, of: url) }
    }

    func touch(_ url: URL) throws {
        if !exists(url) { try write(Data(), to: url, mode: 0o644) }
    }

    /// Creates `url` and any missing parents as mode 755; existing directories keep their mode.
    func createDirectory(_ url: URL) throws {
        guard !exists(url) else { return }
        try createDirectory(url.deletingLastPathComponent())
        try fm.createDirectory(at: url, withIntermediateDirectories: false)
        try setMode(0o755, of: url)
    }

    func ensureDirectoryExecutable(_ url: URL) throws {
        guard exists(url) else { return }
        let mode = try currentMode(of: url)
        if mode & 0o100 == 0 { try setMode(mode | 0o100, of: url) }
    }

    func setMode(_ mode: Int, of url: URL) throws {
        try fm.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: url.path)
    }

    private func currentMode(of url: URL) throws -> Int {
        (try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
    }
}
