import Foundation
import Testing
import AlasCore

struct DevicesRailTests {
    private static func booted(_ id: String) -> SimulatorDevice {
        SimulatorDevice(udid: id, name: "iPhone \(id)", runtimeName: "iOS 26.5", state: .booted)
    }

    private static func running(_ ids: [String], android: AndroidListing? = nil) -> [DevicesTabState.Running] {
        DevicesTabState.resolve(
            simulators: ids.map(booted), listError: nil, vms: [:], lastUsed: nil, bootingUDIDs: [],
            agentDriving: [], android: android
        ).running
    }

    /// `expanded` devices, then `collapsed` ones, then `inCenter` ones.
    private static func entries(expanded: Int, collapsed: Int = 0, inCenter: Int = 0) -> [DevicesRail.Entry] {
        let ids = (0..<(expanded + collapsed + inCenter)).map { "s\($0)" }
        let folded = Set(ids.dropFirst(expanded).prefix(collapsed).map(DevicesTarget.simulator))
        let centered = Set(ids.suffix(inCenter).map(DevicesTarget.simulator))
        return DevicesRail.entries(running(ids), collapsed: folded, inCenter: centered)
    }

    @Test func placementFollowsCollapsedDevicesAndCenterTabs() {
        let entries = DevicesRail.entries(
            Self.running(["a", "b", "c"]), collapsed: [.simulator("b"), .simulator("c")],
            inCenter: [.simulator("c"), .simulator("gone")]
        )
        #expect(entries.map(\.id) == [.simulator("a"), .simulator("b"), .simulator("c")])
        #expect(entries.map(\.placement) == [.expanded, .collapsed, .inCenter])
    }

    @Test func aCenterTabFindsItsDeviceOrItsAVDsNewEmulator() {
        let emulator = AndroidDevice(
            serial: "emulator-5556", state: .ready, model: nil, avdName: "Medium_Phone", release: "16"
        )
        let running = Self.running(
            ["on"], android: AndroidListing(devices: [emulator], avds: ["Medium_Phone"], bootingAVDs: [], note: nil)
        )
        #expect(DevicesRail.device(forTab: "on", avdName: nil, in: running)?.id == .simulator("on"))
        #expect(DevicesRail.device(forTab: "emulator-5554", avdName: "Medium_Phone", in: running)?.id
            == .android("emulator-5556"))
        #expect(DevicesRail.device(forTab: "gone", avdName: nil, in: running) == nil)
    }

    struct LayoutCase: Sendable, CustomTestStringConvertible {
        let name: String
        let visibleHeight: Double
        let expanded: Int
        var collapsed = 0
        var inCenter = 0
        var aspect: Double?
        var chrome = DevicesRailLayout.Chrome(horizontal: 76, vertical: 32)
        let height: Double
        var testDescription: String { name }
    }

    @Test(arguments: [
        LayoutCase(name: "one device fills the rail", visibleHeight: 800, expanded: 1, aspect: 2.17, height: 764),
        LayoutCase(name: "rows above it leave the rest", visibleHeight: 800, expanded: 1, collapsed: 1, inCenter: 1,
                   aspect: 2.17, height: 692),
        LayoutCase(name: "two phones share it", visibleHeight: 800, expanded: 2, aspect: 2.17, height: 364),
        LayoutCase(name: "a third expanded scrolls", visibleHeight: 800, expanded: 3, aspect: 2.17, height: 364),
        LayoutCase(name: "a collapsed row takes its height", visibleHeight: 800, expanded: 2, collapsed: 1,
                   aspect: 2.17, height: 346),
        LayoutCase(name: "a VM fits the width", visibleHeight: 800, expanded: 2, aspect: 0.625,
                   chrome: .init(horizontal: 24, vertical: 24), height: 197),
        LayoutCase(name: "no frame yet fills the stage", visibleHeight: 800, expanded: 2, height: 364),
        LayoutCase(name: "a short pane keeps screens usable", visibleHeight: 400, expanded: 2, aspect: 2.17, height: 200),
    ])
    func stagesSplitTheRailTwoAtATime(_ c: LayoutCase) {
        let layout = DevicesRailLayout(
            visibleHeight: c.visibleHeight,
            entries: Self.entries(expanded: c.expanded, collapsed: c.collapsed, inCenter: c.inCenter)
        )
        #expect(layout.height(width: 300, aspect: c.aspect, chrome: c.chrome) == c.height)
    }
}
