import AlasCore
import Foundation
import Testing
@testable import Alas

// Main actor: GoldenImageInstaller is main-actor-only.
@MainActor
@Suite("GoldenImageInstaller")
struct GoldenImageInstallerTests {
    @Test("an install running in another process is left untouched")
    func installLockHeldElsewhereTouchesNothing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoldenImageInstallerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let partial = root.appendingPathComponent("golden/25A1.partial", isDirectory: true)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        // A separate open file description conflicts like another process.
        let otherInstall = try ComputerUseDriverLock.acquire(
            at: root.appendingPathComponent("install.lock"), label: "Alas Dev")
        defer { otherInstall.release() }

        let installer = GoldenImageInstaller(root: root)
        await installer.start()

        #expect(installer.phase == .failed("macOS is being set up in another Alas."))
        #expect(FileManager.default.fileExists(atPath: partial.path))
    }
}
