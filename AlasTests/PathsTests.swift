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
}
