import AlasCore
import Foundation
import Testing
@testable import Alas

struct DeviceLogsTabStateTests {
    /// Logs tabs saved before Android had logs carry no platform: they are a simulator's.
    @Test func aTabSavedWithoutAPlatformRestoresAsASimulators() throws {
        let saved = try JSONEncoder().encode(Tab.simulatorLogs(SimulatorLogsTabState(
            worktreeId: "w", udid: "8CA9B1E8-EE67-49E5-846F-293450990F76", deviceName: "iPhone", platform: .android
        )))
        let json = String(decoding: saved, as: UTF8.self).replacingOccurrences(of: #","platform":"android""#, with: "")
            .replacingOccurrences(of: #""platform":"android","#, with: "")
        #expect(!json.contains("platform"))
        guard case .simulatorLogs(let restored) = try JSONDecoder().decode(Tab.self, from: Data(json.utf8)) else {
            Issue.record("not a logs tab")
            return
        }
        #expect(restored.platform == .ios)
        #expect(restored.udid == "8CA9B1E8-EE67-49E5-846F-293450990F76")
    }
}
