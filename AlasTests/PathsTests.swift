import Testing
import Foundation
@testable import Alas

struct PathsTests {
    @Test func appSupportRootEndsWithAlas() {
        let url = Paths.appSupportRoot
        #expect(url.lastPathComponent == "Alas")
    }

    @Test func childPathsLiveUnderAppSupport() {
        let app = Paths.appConfigFile
        let projects = Paths.projectsFile
        let tabs = Paths.tabsDir
        for url in [app, projects, tabs] {
            #expect(url.path.hasPrefix(Paths.appSupportRoot.path))
        }
    }

    @Test func ensureCreatesAppSupportDir() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-paths-\(UUID().uuidString)")
        try Paths.ensureDirectoryExists(tmp)
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: tmp.path, isDirectory: &isDir))
        #expect(isDir.boolValue)
        try? FileManager.default.removeItem(at: tmp)
    }

    @Test(arguments: [
        ([:], AlasProfile.Resolution.standard),
        (["ALAS_APP_SUPPORT_DIR": "  "], .standard),
        (["ALAS_APP_SUPPORT_DIR": "scratch/profile"], .invalid("scratch/profile")),
        (["ALAS_APP_SUPPORT_DIR": "/tmp/e2e/../profile/"], .isolated(URL(fileURLWithPath: "/tmp/profile", isDirectory: true))),
    ])
    func profileOverrideResolution(environment: [String: String], expected: AlasProfile.Resolution) {
        #expect(AlasProfile.resolve(environment: environment) == expected)
    }

    @Test func runtimeDirectoryIsShortAndDistinctPerProfile() {
        let long = URL(fileURLWithPath: "/private/tmp/" + String(repeating: "x", count: 200))
        let other = URL(fileURLWithPath: "/tmp/other-profile")
        let dir = AlasProfile.runtimeDirectory(for: long, uid: 501)
        #expect(dir.path.hasPrefix("/tmp/alas-501-"))
        #expect(dir.path.utf8.count <= 23)
        #expect(dir == AlasProfile.runtimeDirectory(for: long, uid: 501))
        #expect(dir != AlasProfile.runtimeDirectory(for: other, uid: 501))
    }

    @Test func privateDirectoryIsCreatedOrTightenedToOwnerOnly() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("alas-profile-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let fresh = base.appendingPathComponent("fresh")
        let loose = base.appendingPathComponent("loose")
        try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        for url in [fresh, loose] {
            #expect(AlasProfile.preparePrivateDirectory(url, ownerUid: getuid()))
            let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
            #expect(mode == 0o700)
        }
    }

    @Test func privateDirectoryRefusesASymlink() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("alas-profile-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let target = base.appendingPathComponent("target")
        let link = base.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(!AlasProfile.preparePrivateDirectory(link, ownerUid: getuid()))
    }

    @Test func aliasedSpellingsOfAProfileShareOneIdentity() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("alas-profile-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let real = base.appendingPathComponent("real/Profile")
        let alias = base.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real.deletingLastPathComponent())
        let viaAlias = try #require(AlasProfile.canonicalDirectory(alias.appendingPathComponent("Profile")))
        let direct = try #require(AlasProfile.canonicalDirectory(real))
        #expect(viaAlias == direct)
        #expect(AlasProfile.runtimeDirectory(for: viaAlias, uid: 501) == AlasProfile.runtimeDirectory(for: direct, uid: 501))
    }
}
