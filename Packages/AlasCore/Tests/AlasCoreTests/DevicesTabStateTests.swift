import Foundation
import Testing
import AlasCore

struct DevicesTabStateTests {
    static let off = SimulatorDevice(udid: "off", name: "iPhone 17", runtimeName: "iOS 26.5", state: .shutdown)
    static let on = SimulatorDevice(udid: "on", name: "iPhone Air", runtimeName: "iOS 26.5", state: .booted)
    static let stoppedVMs: [VMGuestOS: VMDeviceStatus] = [.macOS: .stopped, .linux: .notCreated]

    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        var simulators: [SimulatorDevice]? = [off, on]
        var listError: String? = nil
        var vms: [VMGuestOS: VMDeviceStatus] = [:]
        var selection: DevicesTarget? = nil
        var booting: Set<String> = []
        let stage: DevicesTabState.Stage
        var testDescription: String { name }
    }

    private func resolve(_ c: Case) -> DevicesTabState {
        .resolve(
            simulators: c.simulators, listError: c.listError, vms: c.vms, selection: c.selection,
            bootingUDIDs: c.booting, agentDriving: []
        )
    }

    @Test(arguments: [
        Case(name: "a selected simulator stays", selection: .simulator("off"), stage: .simulator(off, .shutDown)),
        Case(name: "a deleted simulator falls back to the first booted", selection: .simulator("gone"),
             stage: .simulator(on, .booted)),
        Case(name: "a selected VM that doesn't exist yet stays", vms: stoppedVMs, selection: .vm(.linux),
             stage: .vm(.linux, .notCreated)),
        Case(name: "a VM selection on a Mac without VMs falls back", selection: .vm(.macOS),
             stage: .simulator(on, .booted)),
    ])
    func selectionFallsBackOnlyWhenItsDeviceIsGone(_ c: Case) {
        #expect(resolve(c).stage == c.stage)
    }

    @Test(arguments: [
        Case(name: "a booted simulator first", vms: [.macOS: .running, .linux: .notCreated], stage: .simulator(on, .booted)),
        Case(name: "then a running VM", simulators: [off], vms: [.macOS: .stopped, .linux: .running],
             stage: .vm(.linux, .running)),
        Case(name: "then the first simulator", simulators: [off], vms: stoppedVMs, stage: .simulator(off, .shutDown)),
    ])
    func defaultPrefersABootedSimulatorThenARunningVM(_ c: Case) {
        #expect(resolve(c).stage == c.stage)
    }

    @Test func noSimulatorsFallsBackToTheMacOSVM() {
        let noXcode = resolve(Case(name: "", simulators: nil, listError: "no simctl", vms: Self.stoppedVMs, stage: .loading))
        #expect(noXcode.stage == .vm(.macOS, .stopped))
        #expect(noXcode.simulatorsNote == "Install Xcode to use iOS simulators")
        let none = resolve(Case(name: "", simulators: [], vms: Self.stoppedVMs, stage: .loading))
        #expect(none.stage == .vm(.macOS, .stopped))
        #expect(none.simulatorsNote == "No iOS simulators")
        #expect(resolve(Case(name: "", simulators: nil, listError: "no simctl", stage: .loading)).stage
            == .unavailable("no simctl"))
        #expect(resolve(Case(name: "", simulators: [], stage: .loading)).stage == .noSimulators)
    }

    @Test func loadingDoesNotJumpToAStoppedVM() {
        #expect(resolve(Case(name: "", simulators: nil, vms: Self.stoppedVMs, stage: .loading)).stage == .loading)
        #expect(resolve(Case(name: "", simulators: nil, vms: [.macOS: .running], stage: .loading)).stage
            == .vm(.macOS, .running))
    }

    @Test func bootingCountsBeforeSimctlSaysSo() {
        let state = resolve(Case(name: "", selection: .simulator("off"), booting: ["off"], stage: .loading))
        #expect(state.stage == .simulator(Self.off, .booting))
        #expect(state.simulatorRows.first { $0.target == .simulator("off") }?.tone == .busy)
    }

    @Test(arguments: [
        (VMDeviceStatus.running, "Running", DevicesTabState.Tone.live),
        (.starting, "Starting", .busy),
        (.pausing, "Pausing", .busy),
        (.paused(savedAt: .distantPast), "Paused", .idle),
        (.stopped, "Stopped", .idle),
        (.runningElsewhere(label: "Alas Dev"), "In Alas Dev", .idle),
        (.notCreated, "Not created", .idle),
    ])
    func vmRowsCarryToneAndDetail(status: VMDeviceStatus, detail: String, tone: DevicesTabState.Tone) {
        let row = resolve(Case(name: "", vms: [.macOS: status], stage: .loading)).vmRows.first
        #expect(row?.title == "macOS VM")
        #expect(row?.detail == detail)
        #expect(row?.tone == tone)
    }

    @Test func anAgentDrivingMakesARowBusy() {
        let state = DevicesTabState.resolve(
            simulators: [Self.on], listError: nil, vms: [.macOS: .running], selection: nil,
            bootingUDIDs: [], agentDriving: [.simulator("on"), .vm(.macOS)]
        )
        #expect(state.simulatorRows.map(\.tone) == [.busy])
        #expect(state.vmRows.map(\.tone) == [.busy])
        #expect(state.simulatorRows.first?.detail == "iOS 26.5")
    }
}
