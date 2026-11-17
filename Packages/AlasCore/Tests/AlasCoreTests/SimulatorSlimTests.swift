import Foundation
import Testing
@testable import AlasCore

struct SimulatorSlimTests {
    @Test func statusAndMeasureMakeTheState() throws {
        let state = try SimulatorSlim.state(
            status: Data(#"{"managedDisabled":149,"managedTotal":173,"booted":true,"persistent":true,"verdict":"partially slim"}"#.utf8),
            measure: Data(#"{"processes":76,"bytes":998579814,"cpu":12.5}"#.utf8)
        )
        #expect(state == SimulatorSlimState(servicesOff: 149, services: 173, persistent: true, memoryBytes: 998_579_814, processes: 76))
        #expect(state.isSlim)
        #expect(state.json["memory_mb"] as? Int == 952)
    }

    @Test func anUnreadableMeasureLeavesMemoryOut() throws {
        let state = try SimulatorSlim.state(
            status: Data(#"{"managedDisabled":0,"managedTotal":173,"persistent":false}"#.utf8), measure: Data("{}".utf8)
        )
        #expect(!state.isSlim)
        #expect(!state.persistent)
        #expect(state.memoryBytes == nil)
        #expect(state.json["memory_mb"] == nil)
    }

    @Test func statusWithoutCountsIsAFailure() {
        #expect(throws: SimulatorSlimError.self) { try SimulatorSlim.state(status: Data(#"{"booted":true}"#.utf8), measure: nil) }
    }

    @Test func everyCategoryComesFromProfiles() throws {
        let profiles = Data(#"[{"id":"widgets","labels":["com.apple.chronod"]},{"id":"siri"},{"id":"store"}]"#.utf8)
        #expect(try SimulatorSlim.categories(profiles) == ["widgets", "siri", "store"])
    }

    @Test(arguments: [
        ("simslim: no simulator with udid X\n", "no simulator with udid X"),
        ("Slimming X…\nsimslim: simulator must be booted to read its state (it is Shutdown)\n",
         "simulator must be booted to read its state (it is Shutdown)"),
        ("", "simslim exited with status 1"),
    ])
    func aFailureNamesSimslimsReason(stderr: String, reason: String) {
        #expect(SimulatorSlim.failure(stderr: stderr, exitCode: 1) == .failed(reason))
    }
}
