import AlasFoundation
import CommonCrypto
import Foundation
import Testing
@testable import AlasPlatform

struct VMGuestProvisioningTests {
    private static let kcpasswordKey: [UInt8] = [0x7D, 0x89, 0x52, 0x23, 0xD2, 0xBC, 0xDD, 0xEA, 0xA3, 0xB9, 0x1F]

    /// `expectedPrefix` covers the password and its first NUL terminator, which
    /// every encoder agrees on. cirruslabs' published "admin" file
    /// (`1ced3f4abcbcba2ccaca4e82`) has a different tail after that terminator,
    /// so only the prefix is pinned; the rest must decode to NUL padding.
    @Test(arguments: [
        ("admin", "1ced3f4abcbc", 12),
        ("alas", "1ce53350d2", 12),
        ("twelve-chars", nil, 24),
    ] as [(String, String?, Int)])
    func kcpasswordMatchesKnownValues(password: String, expectedPrefix: String?, length: Int) {
        let data = VMGuestProvisioning.kcpassword(password)
        #expect(data.count == length)
        if let expectedPrefix {
            #expect(data.prefix(expectedPrefix.count / 2).map { String(format: "%02x", $0) }.joined() == expectedPrefix)
        }
        let decoded = data.enumerated().map { $0.element ^ Self.kcpasswordKey[$0.offset % Self.kcpasswordKey.count] }
        #expect(decoded == Array(password.utf8) + Array(repeating: 0, count: length - password.utf8.count))
    }

    @Test
    func shadowHashVerifiesWithTheSamePassword() throws {
        let salt = Data((0 ..< 32).map { UInt8($0) })
        let data = try VMGuestProvisioning.shadowHashData(password: "alas", salt: salt, iterations: 1_000)
        let plist = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let hash = try #require(plist["SALTED-SHA512-PBKDF2"] as? [String: Any])
        let storedSalt = try #require(hash["salt"] as? Data)
        let iterations = try #require(hash["iterations"] as? Int)
        let entropy = try #require(hash["entropy"] as? Data)
        #expect(storedSalt == salt)
        #expect(entropy.count == 128)
        #expect(pbkdf2("alas", salt: storedSalt, iterations: iterations) == entropy)
        #expect(pbkdf2("not-alas", salt: storedSalt, iterations: iterations) != entropy)
    }

    @Test
    func loginwindowEditKeepsOtherKeysAndDropsFirstLogins() throws {
        let existing: [String: Any] = [
            "AccountInfo": ["FirstLogins": ["alas": 1], "OnConsole": ["x": 1], "Keep": "me"] as [String: Any],
            "OtherKey": "kept",
        ]
        let edited = VMGuestProvisioning.loginwindowPreferences(existing: existing, autoLoginUser: "alas")
        #expect(edited["autoLoginUser"] as? String == "alas")
        #expect(edited["OtherKey"] as? String == "kept")
        let accountInfo = try #require(edited["AccountInfo"] as? [String: Any])
        #expect(accountInfo["FirstLogins"] == nil)
        #expect(accountInfo["Keep"] as? String == "me")
        #expect((accountInfo["OnConsole"] as? [String: Any])?["x"] as? Int == 1)
    }

    @Test
    func tccUpsertTargetsBothServicesForTheHelper() throws {
        let csreq = Data([0xFA, 0xDE, 0x0C, 0x00])
        let db = try SQLiteDatabase(path: ":memory:")
        try db.exec("""
        CREATE TABLE access (service TEXT NOT NULL, client TEXT NOT NULL, client_type INTEGER NOT NULL,
          auth_value INTEGER NOT NULL, auth_reason INTEGER NOT NULL, auth_version INTEGER NOT NULL, csreq BLOB,
          policy_id INTEGER, indirect_object_identifier_type INTEGER,
          indirect_object_identifier TEXT NOT NULL DEFAULT 'UNUSED', indirect_object_code_identity BLOB,
          flags INTEGER, last_modified INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER)),
          pid INTEGER, pid_version INTEGER, boot_uuid TEXT NOT NULL DEFAULT 'UNUSED',
          last_reminded INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (service, client, client_type, indirect_object_identifier))
        """)
        // Running the upsert twice must still leave exactly one row per service.
        for _ in 0 ..< 2 {
            for row in VMGuestProvisioning.tccUpsertSQL(VMGuestProvisioning.TCCGrant.helper(csreq: csreq)) {
                try db.exec(row.sql, bindings: [row.csreq])
            }
        }
        let rows = try db.query(
            "SELECT service, client, client_type, auth_value, auth_reason, csreq FROM access ORDER BY service"
        )
        #expect(rows.compactMap { $0["service"] as? String } == ["kTCCServiceAccessibility", "kTCCServiceScreenCapture"])
        for row in rows {
            #expect(row["client"] as? String == "io.nlopez.vmguest")
            #expect(row["client_type"] as? Int64 == 0)
            #expect(row["auth_value"] as? Int64 == 2)
            #expect(row["auth_reason"] as? Int64 == 4)
            #expect(row["csreq"] as? Data == csreq)
        }
    }

    private func pbkdf2(_ password: String, salt: Data, iterations: Int) -> Data {
        let passwordBytes = Array(password.utf8)
        var out = [UInt8](repeating: 0, count: 128)
        _ = salt.withUnsafeBytes { saltBuffer in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes.map { Int8(bitPattern: $0) }, passwordBytes.count,
                saltBuffer.bindMemory(to: UInt8.self).baseAddress, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512), UInt32(iterations), &out, out.count
            )
        }
        return Data(out)
    }
}
