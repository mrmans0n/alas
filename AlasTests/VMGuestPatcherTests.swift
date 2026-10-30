import AlasCore
import Foundation
import Security
import SQLite3
import Testing
@testable import Alas

@Suite("VMGuestPatcher")
struct VMGuestPatcherTests {
    private static let csreq = Data([0xFA, 0xDE, 0x0C, 0x00, 0x00, 0x00, 0x00, 0x14, 0x01, 0x02, 0x03])
    private static let systemVersion = (product: "27.2", build: "26B123")
    private static let hostUUID = "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9"

    @Test func patchWritesEveryArtefactAndTwoGrants() throws {
        let volume = try Self.makeDataVolume()
        defer { Self.remove(volume) }
        let loginwindow = volume.appendingPathComponent("Library/Preferences/com.apple.loginwindow.plist")
        let loginwindowInode = try Self.inode(of: loginwindow)
        // The host sees the guest's dslocal directories without the search bit.
        try Self.setMode(0o600, of: volume.appendingPathComponent("private/var/db/dslocal/nodes/Default/users"))

        try VMGuestPatcher.patch(
            dataVolume: volume, systemVersion: Self.systemVersion, helperCodeRequirement: Self.csreq, account: .alas
        )

        let dslocal = "private/var/db/dslocal/nodes/Default"
        let user = try Self.plist(volume, "\(dslocal)/users/alas.plist")
        #expect(user["uid"] as? [String] == ["501"])
        #expect(try Self.mode(of: volume.appendingPathComponent("\(dslocal)/users/alas.plist")) == 0o600)
        let generatedUID = try #require((user["generateduid"] as? [String])?.first)
        for group in ["admin", "staff"] {
            let record = try Self.plist(volume, "\(dslocal)/groups/\(group).plist")
            #expect((record["users"] as? [String])?.contains("alas") == true)
            #expect((record["groupmembers"] as? [String])?.contains(generatedUID) == true)
        }

        let home = volume.appendingPathComponent("Users/alas")
        for directory in ["Library/Preferences/ByHost", "Library/LaunchAgents", "Desktop", "Documents", "Downloads"] {
            var isDirectory: ObjCBool = false
            #expect(FileManager.default.fileExists(
                atPath: home.appendingPathComponent(directory).path, isDirectory: &isDirectory
            ) && isDirectory.boolValue, "\(directory)")
        }
        // Never a LaunchAgent: launchd skips host-written (provenance-tagged) ones.
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent("Library/LaunchAgents").path)
            .isEmpty)
        #expect(try String(contentsOf: home.appendingPathComponent(".CFUserTextEncoding"), encoding: .utf8)
            == "0x1F5:0x0:0x0\n")
        for setupAssistant in ["Users/alas/Library/Preferences", "Library/Preferences"] {
            let prefs = try Self.plist(volume, "\(setupAssistant)/com.apple.SetupAssistant.plist")
            #expect(prefs["LastSeenBuddyBuildVersion"] as? String == "26B123")
            #expect(prefs["LastSeenCloudProductVersion"] as? String == "27.2")
        }
        #expect(FileManager.default.fileExists(atPath: volume.appendingPathComponent("private/var/db/.AppleSetupDone").path))

        let login = try Self.plist(volume, "Library/Preferences/com.apple.loginwindow.plist")
        #expect(login["autoLoginUser"] as? String == "alas")
        #expect((login["AccountInfo"] as? [String: Any])?["FirstLogins"] == nil)
        #expect(login["KeptKey"] as? String == "kept")
        #expect(try Self.inode(of: loginwindow) == loginwindowInode, "existing plists are edited in place")
        let kcpassword = volume.appendingPathComponent("private/etc/kcpassword")
        #expect(try Data(contentsOf: kcpassword) == VMGuestProvisioning.kcpassword("alas"))
        #expect(try Self.mode(of: kcpassword) == 0o600)

        let launchd = volume.appendingPathComponent("private/var/db/com.apple.xpc.launchd/disabled.plist")
        var format = PropertyListSerialization.PropertyListFormat.binary
        let disabled = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: launchd), options: [], format: &format
        ) as? [String: Any]
        #expect(format == .xml)
        #expect(disabled?["com.openssh.sshd"] as? Bool == false)
        #expect(disabled?["com.example.kept"] as? Bool == true)
        #expect(FileManager.default.fileExists(atPath: launchd.deletingLastPathComponent()
                .appendingPathComponent("disabled.migrated").path))
        #expect(FileManager.default.fileExists(
            atPath: volume.appendingPathComponent("Library/Preferences/com.apple.PowerManagement.plist").path
        ))
        // The host UUID comes from the system's per-host power plist on a fresh guest.
        #expect(try Self.plist(volume, "Users/alas/Library/Preferences/ByHost/com.apple.screensaver.\(Self.hostUUID).plist")["idleTime"] as? Int == 0)
        #expect(try Self.plist(volume, "Library/Preferences/com.apple.PowerManagement.\(Self.hostUUID).plist")["AC Power"] != nil)

        let rows = try Self.tccRows(volume)
        #expect(rows.map(\.service) == ["kTCCServiceAccessibility", "kTCCServiceScreenCapture"])
        #expect(rows.allSatisfy { $0.client == VMGuestProvisioning.helperBundleID && $0.csreq == Self.csreq })
        // The guest's journal mode is left alone.
        let tccDirectory = volume.appendingPathComponent("Library/Application Support/com.apple.TCC")
        #expect(try FileManager.default.contentsOfDirectory(atPath: tccDirectory.path) == ["TCC.db"])
    }

    @Test func patchIsIdempotent() throws {
        let volume = try Self.makeDataVolume()
        defer { Self.remove(volume) }
        try VMGuestPatcher.patch(
            dataVolume: volume, systemVersion: Self.systemVersion, helperCodeRequirement: Self.csreq, account: .alas
        )
        let first = try Self.snapshot(volume, excluding: "TCC.db")
        try VMGuestPatcher.patch(
            dataVolume: volume, systemVersion: Self.systemVersion, helperCodeRequirement: Self.csreq, account: .alas
        )
        #expect(try Self.snapshot(volume, excluding: "TCC.db") == first)
        #expect(try Self.tccRows(volume).count == 2)
    }

    @Test func patchGrantsChangesOnlyTheGrantsAndSSHD() throws {
        let volume = try Self.makeDataVolume()
        defer { Self.remove(volume) }
        // A guest that has booted before already migrated its launchd overrides.
        let launchd = "private/var/db/com.apple.xpc.launchd/disabled.plist"
        try Data().write(to: volume.appendingPathComponent("private/var/db/com.apple.xpc.launchd/disabled.migrated"))
        let before = try Self.snapshot(volume)

        try VMGuestPatcher.patchGrants(dataVolume: volume, helperCodeRequirement: Self.csreq)

        let after = try Self.snapshot(volume)
        #expect(Set(after.keys) == Set(before.keys))
        #expect(Set(after.keys.filter { after[$0] != before[$0] })
            == [launchd, "Library/Application Support/com.apple.TCC/TCC.db"])
        #expect(try Self.plist(volume, launchd)["com.openssh.sshd"] as? Bool == false)
        let rows = try Self.tccRows(volume)
        #expect(rows.map(\.service) == ["kTCCServiceAccessibility", "kTCCServiceScreenCapture"])
        #expect(rows.allSatisfy { $0.client == VMGuestProvisioning.helperBundleID && $0.csreq == Self.csreq })
    }

    @Test func patchRefusesAVolumeWithoutTCCDatabase() throws {
        let volume = try Self.makeDataVolume()
        defer { Self.remove(volume) }
        try FileManager.default.removeItem(at: volume.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db"))
        let before = try Self.snapshot(volume)

        #expect(throws: VMGuestPatcher.PatchError.self) {
            try VMGuestPatcher.patch(
                dataVolume: volume, systemVersion: Self.systemVersion, helperCodeRequirement: Self.csreq, account: .alas
            )
        }
        #expect(try Self.snapshot(volume) == before)
    }

    @Test func designatedRequirementOfTheEmbeddedHelper() throws {
        let helper = try #require(Bundle.main.resourceURL?
            .appendingPathComponent("alas-vm-guest/Alas VM Guest.app", isDirectory: true))
        let data = try HelperCodeRequirement.designatedRequirementData(of: helper)

        var requirement: SecRequirement?
        #expect(SecRequirementCreateWithData(data as CFData, [], &requirement) == errSecSuccess)
        var code: SecStaticCode?
        #expect(SecStaticCodeCreateWithPath(helper as CFURL, [], &code) == errSecSuccess)
        let staticCode = try #require(code)
        #expect(SecStaticCodeCheckValidity(staticCode, [], try #require(requirement)) == errSecSuccess)
    }

    @Test(
        "the whole disk is the GUID-scheme entity, else the lowest-numbered disk",
        arguments: [
            ([("/dev/disk9", "Apple_APFS_Recovery"), ("/dev/disk10", "GUID_partition_scheme"), ("/dev/disk10s2", "Apple_APFS")],
             "/dev/disk10"),
            ([("/dev/disk11", "Apple_APFS"), ("/dev/disk9s1", "Apple_APFS_ISC"), ("/dev/disk10", "")], "/dev/disk10"),
            ([("/dev/disk4s1", "Apple_APFS_ISC"), ("/dev/disk4s2", "Apple_APFS")], nil),
        ] as [([(String, String)], String?)]
    )
    func wholeDiskSelection(entities: [(String, String)], expected: String?) {
        let plist = entities.map { ["dev-entry": $0.0, "content-hint": $0.1] }
        #expect(VMDiskSession.wholeDisk(inEntities: plist) == expected)
    }

    struct SweepCase: CustomTestStringConvertible, Sendable {
        let name: String
        /// The session's owner pid; 1 is live, 2 dead, nil no owner record.
        let pid: Int?
        let image: String?
        var detachSucceeds = true
        let detached: [String]
        let removed: Bool
        var testDescription: String { name }
    }

    nonisolated static let sweepCases: [SweepCase] = [
        SweepCase(name: "stale record, image attached: detached", pid: 2, image: "/vms/worktrees/a/disk.img",
                  detached: ["/dev/disk7"], removed: true),
        SweepCase(name: "stale record, image not attached: removed", pid: 2, image: "/vms/worktrees/b/disk.img",
                  detached: [], removed: true),
        SweepCase(name: "live record: skipped", pid: 1, image: "/vms/worktrees/a/disk.img",
                  detached: [], removed: false),
        SweepCase(name: "no owner record: kept", pid: nil, image: nil, detached: [], removed: false),
        SweepCase(name: "stale record but the detach fails: kept", pid: 2, image: "/vms/worktrees/a/disk.img",
                  detachSucceeds: false, detached: ["/dev/disk7"], removed: false),
    ]

    @Test("the stale-session sweep detaches only images stale owner records name", arguments: sweepCases)
    func staleSessionSweep(_ c: SweepCase) {
        // `hand.img` is attached from under the VM root with no record: never touched.
        let info: [String: Any] = ["images": [
            ["image-path": "/vms/worktrees/a/disk.img", "system-entities": [["dev-entry": "/dev/disk7"]]],
            ["image-path": "/vms/hand.img", "system-entities": [["dev-entry": "/dev/disk8"]]],
        ]]
        let session = VMDiskSession.SessionRecord(name: "S", pid: c.pid, image: c.image)
        var detached: [String] = []

        let removed = VMDiskSession.staleSessionsToRemove(
            info: info, sessions: [session], isLive: { $0.pid == 1 }
        ) { device in
            detached.append(device)
            return c.detachSucceeds
        }

        #expect(detached == c.detached)
        #expect(removed == (c.removed ? ["S"] : []))
    }

    // MARK: - Fixture

    /// A directory laid out like a freshly booted guest's Data volume.
    private static func makeDataVolume() throws -> URL {
        let fm = FileManager.default
        let volume = fm.temporaryDirectory.appendingPathComponent("VMGuestPatcherTests-\(UUID().uuidString)")
        let groups = volume.appendingPathComponent("private/var/db/dslocal/nodes/Default/groups")
        try fm.createDirectory(at: groups, withIntermediateDirectories: true)
        try fm.createDirectory(
            at: volume.appendingPathComponent("private/var/db/dslocal/nodes/Default/users"), withIntermediateDirectories: true
        )
        try writePlist(["name": ["_mbsetupuser"], "uid": ["248"]], to: volume
            .appendingPathComponent("private/var/db/dslocal/nodes/Default/users/_mbsetupuser.plist"))
        for (name, gid) in [("admin", "80"), ("staff", "20")] {
            try writePlist(["name": [name], "gid": [gid], "users": ["root"]], to: groups.appendingPathComponent("\(name).plist"))
        }
        try writePlist(
            ["KeptKey": "kept", "AccountInfo": ["FirstLogins": ["_mbsetupuser": 1]]],
            to: volume.appendingPathComponent("Library/Preferences/com.apple.loginwindow.plist")
        )
        try writePlist(
            ["com.example.kept": true],
            to: volume.appendingPathComponent("private/var/db/com.apple.xpc.launchd/disabled.plist")
        )
        try writePlist([:], to: volume.appendingPathComponent("Library/Preferences/com.apple.PowerManagement.\(hostUUID).plist"))
        try fm.createDirectory(at: volume.appendingPathComponent("private/etc"), withIntermediateDirectories: true)

        let tcc = volume.appendingPathComponent("Library/Application Support/com.apple.TCC")
        try fm.createDirectory(at: tcc, withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(tcc.appendingPathComponent("TCC.db").path, &db) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(db) }
        let schema = """
        CREATE TABLE access (service TEXT NOT NULL, client TEXT NOT NULL, client_type INTEGER NOT NULL,
          auth_value INTEGER NOT NULL, auth_reason INTEGER NOT NULL, auth_version INTEGER NOT NULL, csreq BLOB,
          policy_id INTEGER, indirect_object_identifier_type INTEGER,
          indirect_object_identifier TEXT NOT NULL DEFAULT 'UNUSED', indirect_object_code_identity BLOB,
          flags INTEGER, last_modified INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER)),
          pid INTEGER, pid_version INTEGER, boot_uuid TEXT NOT NULL DEFAULT 'UNUSED',
          last_reminded INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (service, client, client_type, indirect_object_identifier))
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        return volume
    }

    private static func remove(_ volume: URL) {
        // Restore search bits a test may have cleared so the tree can be deleted.
        if let enumerator = FileManager.default.enumerator(atPath: volume.path) {
            for case let path as String in enumerator {
                let url = volume.appendingPathComponent(path)
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    try? setMode(0o755, of: url)
                }
            }
        }
        try? FileManager.default.removeItem(at: volume)
    }

    private static func writePlist(_ plist: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: url)
    }

    private static func plist(_ volume: URL, _ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: volume.appendingPathComponent(path))
        return try #require(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
    }

    private static func mode(of url: URL) throws -> Int {
        try #require((FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue)
    }

    private static func setMode(_ mode: Int, of url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: url.path)
    }

    private static func inode(of url: URL) throws -> UInt64 {
        try #require((FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)?.uint64Value)
    }

    /// Every item's relative path, mode, and (for files) contents.
    private static func snapshot(_ volume: URL, excluding excluded: String? = nil) throws -> [String: String] {
        var result: [String: String] = [:]
        let enumerator = try #require(FileManager.default.enumerator(atPath: volume.path))
        for case let path as String in enumerator where (path as NSString).lastPathComponent != excluded {
            let url = volume.appendingPathComponent(path)
            let data = (try? Data(contentsOf: url))?.base64EncodedString() ?? "<dir>"
            result[path] = "\(try mode(of: url)) \(data)"
        }
        return result
    }

    private struct TCCRow {
        var service: String
        var client: String
        var csreq: Data?
    }

    private static func tccRows(_ volume: URL) throws -> [TCCRow] {
        let path = volume.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT service, client, csreq FROM access ORDER BY service", -1, &statement, nil)
            == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_finalize(statement) }
        var rows: [TCCRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let blob = sqlite3_column_blob(statement, 2).map { Data(bytes: $0, count: Int(sqlite3_column_bytes(statement, 2))) }
            rows.append(TCCRow(
                service: String(cString: sqlite3_column_text(statement, 0)),
                client: String(cString: sqlite3_column_text(statement, 1)),
                csreq: blob
            ))
        }
        return rows
    }
}
