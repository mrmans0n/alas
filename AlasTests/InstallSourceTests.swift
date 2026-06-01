import Foundation
import Testing
@testable import Alas

struct InstallSourceTests {
    @Test func detectsHomebrewWhenCaskroomDirExists() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("alas-caskroom-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let source = InstallSource.detect(caskroomPaths: [tmp.path])
        #expect(source == .homebrew)
    }

    @Test func detectsDirectWhenNoCaskroomDir() {
        let missing = "/tmp/definitely-not-a-caskroom-\(UUID().uuidString)"
        #expect(InstallSource.detect(caskroomPaths: [missing]) == .direct)
    }

    @Test func ignoresPlainFileAtCaskroomPath() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("alas-caskroom-file-\(UUID().uuidString)")
        try Data().write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        #expect(InstallSource.detect(caskroomPaths: [tmp.path]) == .direct)
    }
}
