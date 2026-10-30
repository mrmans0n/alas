import CommonCrypto
import Foundation

/// The local account Alas creates in an unattended golden image. A throwaway
/// VM's password is not a secret.
public struct VMGuestAccount: Equatable, Sendable {
    public var shortName: String
    public var fullName: String
    public var uid: Int
    public var password: String

    public init(shortName: String, fullName: String, uid: Int, password: String) {
        self.shortName = shortName
        self.fullName = fullName
        self.uid = uid
        self.password = password
    }

    public static let alas = VMGuestAccount(shortName: "alas", fullName: "Alas", uid: 501, password: "alas")

    public var homeDirectory: String { "/Users/\(shortName)" }
}

public enum VMGuestProvisioningError: Error, Equatable {
    case invalidSalt(length: Int)
    case keyDerivationFailed(status: Int32)
    case invalidIterations(Int)
}

/// Pure content for patching a stopped macOS guest's Data volume offline.
///
/// The dslocal, SetupAssistant, loginwindow, kcpassword, sshd and power/lock
/// shapes are ported from trycua/cua `libs/lume`
/// `src/Unattended/MacOSOfflineSetupPatcher.swift` (MIT).
public enum VMGuestProvisioning {
    public static let helperBundleID = "io.nlopez.vmguest"
    public static let defaultIterations = 50000
    public static let saltLength = 32
    public static let entropyLength = 128
    /// The guest's `staff` group.
    public static let staffGID = 20

    // MARK: - Password material

    /// `/etc/kcpassword` bytes: the UTF-8 password padded with NULs to a
    /// multiple of 12 (always at least one NUL, so a 12-byte password grows to
    /// 24), XORed with the fixed key. Padding before the XOR matters: raw NULs
    /// in the file decode to key bytes and break the login keychain unlock.
    public static func kcpassword(_ password: String) -> Data {
        let key: [UInt8] = [0x7D, 0x89, 0x52, 0x23, 0xD2, 0xBC, 0xDD, 0xEA, 0xA3, 0xB9, 0x1F]
        var plaintext = Array(password.utf8)
        plaintext.append(contentsOf: [UInt8](repeating: 0, count: 12 - plaintext.count % 12))
        return Data(plaintext.enumerated().map { $0.element ^ key[$0.offset % key.count] })
    }

    /// A fresh random salt for `shadowHashData`.
    public static func randomSalt() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0 ..< saltLength).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    /// The dslocal `ShadowHashData` value: a binary plist holding a
    /// `SALTED-SHA512-PBKDF2` dictionary (`entropy`, `salt`, `iterations`).
    public static func shadowHashData(
        password: String, salt: Data, iterations: Int = defaultIterations
    ) throws -> Data {
        guard salt.count == saltLength else { throw VMGuestProvisioningError.invalidSalt(length: salt.count) }
        // A corrupt record may hold any count; PBKDF2 takes a positive UInt32.
        guard let rounds = UInt32(exactly: iterations), rounds > 0 else {
            throw VMGuestProvisioningError.invalidIterations(iterations)
        }
        let passwordBytes = Array(password.utf8)
        var entropy = [UInt8](repeating: 0, count: entropyLength)
        let status = salt.withUnsafeBytes { saltBuffer in
            passwordBytes.withUnsafeBufferPointer { passwordBuffer in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBuffer.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: Int8.self) },
                    passwordBytes.count,
                    saltBuffer.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512), rounds,
                    &entropy, entropy.count
                )
            }
        }
        guard status == kCCSuccess else { throw VMGuestProvisioningError.keyDerivationFailed(status: status) }
        let shadow: [String: Any] = [
            "SALTED-SHA512-PBKDF2": ["entropy": Data(entropy), "iterations": iterations, "salt": salt] as [String: Any],
        ]
        return try PropertyListSerialization.data(fromPropertyList: shadow, format: .binary, options: 0)
    }

    // MARK: - dslocal

    /// The `dslocal/nodes/Default/users/<name>.plist` record. dslocal stores
    /// every attribute as an array, numbers as strings.
    public static func userRecord(_ account: VMGuestAccount, generatedUID: UUID, shadowHash: Data) -> [String: Any] {
        let name = account.shortName
        return [
            "_writers_UserCertificate": [name],
            "_writers_hint": [name],
            "_writers_jpegphoto": [name],
            "_writers_passwd": [name],
            "_writers_picture": [name],
            "_writers_realname": [name],
            "record_daemon_version": ["9040000"],
            "unlockOptions": ["0"],
            "ShadowHashData": [shadowHash],
            "authentication_authority": [";ShadowHash;HASHLIST:<SALTED-SHA512-PBKDF2>"],
            "generateduid": [generatedUID.uuidString.uppercased()],
            "gid": [String(staffGID)],
            "home": [account.homeDirectory],
            "name": [name],
            "passwd": ["********"],
            "realname": [account.fullName],
            "shell": ["/bin/zsh"],
            "uid": [String(account.uid)],
        ]
    }

    /// Adds the account to a dslocal group record (`admin`, `staff`) by name
    /// and generated UID, keeping every other key.
    public static func groupMembershipEdit(
        groupPlist: [String: Any], adding account: VMGuestAccount, generatedUID: UUID
    ) -> [String: Any] {
        var group = groupPlist
        var users = group["users"] as? [String] ?? []
        if !users.contains(account.shortName) { users.append(account.shortName) }
        group["users"] = users
        let uuid = generatedUID.uuidString.uppercased()
        var members = group["groupmembers"] as? [String] ?? []
        if !members.contains(uuid) { members.append(uuid) }
        group["groupmembers"] = members
        return group
    }

    // MARK: - Setup Assistant and login

    /// `com.apple.SetupAssistant.plist` marking every first-login pane seen,
    /// keyed to the guest's own macOS version.
    public static func setupAssistantPreferences(productVersion: String, buildVersion: String) -> [String: Any] {
        [
            "DidSeeCloudSetup": true,
            "DidSeePrivacy": true,
            "DidSeeSiriSetup": true,
            "DidSeeTouchIDSetup": true,
            "DidSeeTrueToneSetup": true,
            "GestureMovieSeen": "none",
            "LastSeenBuddyBuildVersion": buildVersion,
            "LastSeenCloudProductVersion": productVersion,
        ]
    }

    /// `/Library/Preferences/com.apple.loginwindow.plist` with auto-login.
    /// A `FirstLogins` entry makes macOS run Setup Assistant at the next
    /// graphical login even with `.AppleSetupDone` present, so it is dropped.
    public static func loginwindowPreferences(existing: [String: Any], autoLoginUser: String) -> [String: Any] {
        var loginwindow = existing
        var accountInfo = loginwindow["AccountInfo"] as? [String: Any] ?? [:]
        accountInfo.removeValue(forKey: "FirstLogins")
        accountInfo["MaximumUsers"] = max(accountInfo["MaximumUsers"] as? Int ?? 1, 1)
        accountInfo["OnConsole"] = accountInfo["OnConsole"] as? [String: Any] ?? [:]
        loginwindow["AccountInfo"] = accountInfo
        loginwindow["autoLoginUser"] = autoLoginUser
        loginwindow["GuestEnabled"] = false
        loginwindow["lastUser"] = "loggedIn"
        loginwindow["lastUserName"] = autoLoginUser
        loginwindow["RecentUsers"] = [autoLoginUser]
        loginwindow["SHOWFULLNAME"] = false
        return loginwindow
    }

    /// A per-user LaunchAgent that keeps `executable` running in the GUI
    /// session. Written from inside the guest: launchd skips host-written
    /// (provenance-tagged) agents.
    public static func launchAgentPlist(label: String, executable: String) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Interactive",
        ]
    }

    // MARK: - sshd

    /// `/private/var/db/com.apple.xpc.launchd/disabled.plist` with sshd on.
    public static func sshdEnabled(disabledPlist existing: [String: Any]) -> [String: Any] {
        settingSSHDDisabled(false, in: existing)
    }

    /// `/private/var/db/com.apple.xpc.launchd/disabled.plist` with sshd off.
    public static func sshdDisabled(disabledPlist existing: [String: Any]) -> [String: Any] {
        settingSSHDDisabled(true, in: existing)
    }

    private static func settingSSHDDisabled(_ disabled: Bool, in existing: [String: Any]) -> [String: Any] {
        var plist = existing
        plist["com.openssh.sshd"] = disabled
        return plist
    }

    // MARK: - Power and lock

    /// The user's `Library/Preferences/.GlobalPreferences.plist`: full
    /// keyboard access.
    public static func userGlobalPreferences(existing: [String: Any]) -> [String: Any] {
        existing.merging(["AppleKeyboardUIMode": 3]) { _, new in new }
    }

    /// The user's `Library/Preferences/com.apple.screensaver.plist`: no
    /// screensaver, no password to wake.
    public static func userScreensaverPreferences(existing: [String: Any]) -> [String: Any] {
        existing.merging(["askForPassword": 0, "askForPasswordDelay": 0, "idleTime": 0]) { _, new in new }
    }

    /// The user's `ByHost/com.apple.screensaver.<uuid>.plist`.
    public static var byHostScreensaverPreferences: [String: Any] { ["idleTime": 0] }

    /// `/Library/Preferences/.GlobalPreferences.plist`: never log out idle users.
    public static func systemGlobalPreferences(existing: [String: Any]) -> [String: Any] {
        existing.merging(["com.apple.autologout.AutoLogOutDelay": 0]) { _, new in new }
    }

    /// `/Library/Preferences/com.apple.PowerManagement.plist`: never sleep.
    public static var powerManagementPreferences: [String: Any] {
        [
            "AC Power": [
                "Automatic Restart On Power Loss": true,
                "DarkWakeBackgroundTasks": 0,
                "Disk Sleep Timer": 0,
                "Display Sleep Timer": 0,
                "System Sleep Timer": 0,
                "Wake On LAN": 1,
            ] as [String: Any],
            "SystemPowerSettings": ["Update DarkWakeBG Setting": true],
        ]
    }

    /// `/Library/Preferences/com.apple.PowerManagement.<uuid>.plist`, one per
    /// ByHost UUID: no standby, no sleep services.
    public static var perHostPowerManagementPreferences: [String: Any] {
        [
            "AC Power": [
                "PrioritizeNetworkReachabilityOverSleep": 0,
                "Sleep On Power Button": false,
                "SleepServices": 0,
                "Standby Delay": 0,
                "Standby Enabled": 0,
                "TCPKeepAlivePref": 1,
                "TTYSPreventSleep": 1,
            ] as [String: Any],
        ]
    }

    // MARK: - TCC

    /// One row in the system `TCC.db` `access` table, for a bundle-id client.
    public struct TCCGrant: Equatable, Sendable {
        public var service: String
        public var client: String
        /// The client's compiled designated requirement.
        public var csreq: Data

        public init(service: String, client: String, csreq: Data) {
            self.service = service
            self.client = client
            self.csreq = csreq
        }

        /// Accessibility and Screen Recording for the guest helper.
        public static func helper(csreq: Data) -> [TCCGrant] {
            ["kTCCServiceAccessibility", "kTCCServiceScreenCapture"].map {
                TCCGrant(service: $0, client: VMGuestProvisioning.helperBundleID, csreq: csreq)
            }
        }
    }

    /// `INSERT OR REPLACE` statements for the system `TCC.db`, one per grant:
    /// bundle-id client (`client_type` 0), allowed (`auth_value` 2),
    /// `auth_reason` 4, `auth_version` 1. `csreq` is the only bound parameter.
    public static func tccUpsertSQL(_ grants: [TCCGrant]) -> [(sql: String, csreq: Data)] {
        grants.map { grant in
            let sql = """
            INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, \
            csreq, policy_id, indirect_object_identifier_type, indirect_object_identifier, \
            indirect_object_code_identity, flags, last_modified, pid, pid_version, boot_uuid, last_reminded) \
            VALUES (\(sqlLiteral(grant.service)), \(sqlLiteral(grant.client)), 0, 2, 4, 1, ?, NULL, NULL, \
            'UNUSED', NULL, 0, CAST(strftime('%s','now') AS INTEGER), NULL, NULL, 'UNUSED', 0)
            """
            return (sql, grant.csreq)
        }
    }

    private static func sqlLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }
}
