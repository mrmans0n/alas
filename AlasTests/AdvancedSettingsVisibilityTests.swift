import Foundation
import Testing
@testable import Alas

struct AdvancedSettingsVisibilityTests {
    @Test func enabledWhenDebugFileExistsEvenIfEmpty() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-debug-visibility-\(UUID().uuidString)", isDirectory: true)
        let debugFile = root.appendingPathComponent(".debug")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: debugFile)

        #expect(AdvancedSettingsVisibility.isEnabled(debugFileURL: debugFile))
    }

    @Test func disabledWhenDebugPathIsMissingOrDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-debug-visibility-\(UUID().uuidString)", isDirectory: true)
        let missing = root.appendingPathComponent(".debug")
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(AdvancedSettingsVisibility.isEnabled(debugFileURL: missing) == false)

        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        #expect(AdvancedSettingsVisibility.isEnabled(debugFileURL: missing) == false)
    }
}
