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
}
