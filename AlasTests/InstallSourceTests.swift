import Foundation
import Testing
@testable import Alas

struct InstallSourceTests {
    private let appPath = "/Applications/Alas.app"

    @Test func detectsHomebrewWhenRunningFromInstallPathAndCaskroomExists() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("alas-caskroom-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let source = InstallSource.detect(
            bundlePath: appPath, appInstallPath: appPath, caskroomPaths: [tmp.path]
        )
        #expect(source == .homebrew)
    }

    @Test func detectsDirectWhenNoCaskroomDir() {
        let missing = "/tmp/definitely-not-a-caskroom-\(UUID().uuidString)"
        #expect(InstallSource.detect(
            bundlePath: appPath, appInstallPath: appPath, caskroomPaths: [missing]
        ) == .direct)
    }

    @Test func ignoresPlainFileAtCaskroomPath() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("alas-caskroom-file-\(UUID().uuidString)")
        try Data().write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        #expect(InstallSource.detect(
            bundlePath: appPath, appInstallPath: appPath, caskroomPaths: [tmp.path]
        ) == .direct)
    }

    @Test func detectsDirectWhenRunningOutsideInstallPathEvenIfCaskroomExists() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("alas-caskroom-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // A separately-downloaded DMG/dev copy running from elsewhere must NOT be
        // classified as Homebrew even though a cask exists on the machine.
        let source = InstallSource.detect(
            bundlePath: "/Users/someone/Downloads/Alas.app",
            appInstallPath: appPath,
            caskroomPaths: [tmp.path]
        )
        #expect(source == .direct)
    }
}
