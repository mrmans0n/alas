import Foundation
import Testing
@testable import Alas

@Suite("ACPSetupChecker")
struct ACPSetupCheckerTests {
    @Test("binaryOnPath returns ready when /bin/ls is on PATH")
    func binaryPresent() async {
        let checker = ACPSetupChecker(env: ProcessInfo.processInfo.environment)
        let r = await checker.evaluate(.binaryOnPath(name: "ls"))
        #expect(r == .ready)
    }

    @Test("binaryOnPath returns missing when binary absent")
    func binaryAbsent() async {
        let checker = ACPSetupChecker(env: ["PATH": "/var/empty"])
        let r = await checker.evaluate(.binaryOnPath(name: "ls"))
        if case .missing = r {} else { Issue.record("expected .missing") }
    }
}
