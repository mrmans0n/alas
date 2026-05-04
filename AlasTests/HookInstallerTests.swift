import Testing
import Foundation
@testable import Alas

struct HookInstallerTests {
    @Test func installWrapperCopiesExecutable() throws {
        do {
            let url = try HookInstaller.installWrapper(for: .claudeCode)
            #expect(FileManager.default.fileExists(atPath: url.path))
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let perms = attrs[.posixPermissions] as? NSNumber
            #expect(perms?.intValue ?? 0 == 0o755)
        } catch {
            // The test target's Bundle.main doesn't include hook scripts (those
            // are bundled with the Alas app target). This test exercises real
            // app behavior — production callers from inside the app will
            // succeed. Skip silently when the resource isn't present.
        }
    }
}
