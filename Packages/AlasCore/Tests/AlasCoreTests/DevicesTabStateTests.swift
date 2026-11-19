import Foundation
import Testing
import AlasCore

struct DevicesTabStateTests {
    static let off = SimulatorDevice(udid: "off", name: "iPhone 17", runtimeName: "iOS 26.5", state: .shutdown)
    static let on = SimulatorDevice(udid: "on", name: "iPhone Air", runtimeName: "iOS 26.5", state: .booted)
    static let old = SimulatorDevice(udid: "old", name: "iPhone 16e", runtimeName: "iOS 18.6", state: .shutdown)
    static let mid = SimulatorDevice(udid: "mid", name: "iPad Pro", runtimeName: "iOS 26.0", state: .shutdown)
    static let stoppedVMs: [VMGuestOS: VMDeviceStatus] = [.macOS: .stopped, .linux: .notCreated]

    static let emulator = AndroidDevice(
        serial: "emulator-5554", state: .ready, model: "sdk_gphone64_arm64", avdName: "Medium_Phone", release: "16"
    )
    static let phone = AndroidDevice(serial: "R5CT", state: .unauthorized, model: nil)

    private func resolve(
        simulators: [SimulatorDevice]? = [off], vms: [VMGuestOS: VMDeviceStatus] = [:],
        lastUsed: DevicesTarget? = nil, android: AndroidListing?
    ) -> DevicesTabState {
        .resolve(
            simulators: simulators, listError: nil, vms: vms, lastUsed: lastUsed,
            bootingUDIDs: [], agentDriving: [], android: android
        )
    }

    @Test func rowsCarryStatusAndBootability() {
        let state = DevicesTabState.resolve(
            simulators: [Self.off, Self.on], listError: nil, vms: [.macOS: .stopped], lastUsed: nil,
            bootingUDIDs: [], agentDriving: [.simulator("on"), .android("emulator-5554")],
            android: AndroidListing(devices: [Self.emulator], avds: ["Medium_Phone", "Pixel_9"], bootingAVDs: [], note: nil),
            agentNames: [.simulator("on"): "Claude"]
        )
        #expect(state.simulatorRows.map(\.status) == ["Shut down", "Claude driving"])
        #expect(state.simulatorRows.map(\.canBoot) == [true, false])
        #expect(state.androidRows.map(\.status) == ["Agent driving", "Shut down"])
        #expect(state.androidRows.map(\.canBoot) == [false, true])
        #expect(state.vmRows.map(\.status) == ["Stopped"])
        #expect(state.vmRows.map(\.canBoot) == [false])
        #expect(state.vmRows.map(\.platform) == [.vm(.macOS)])
    }

    @Test func androidRowsListDevicesThenAVDsThatArentRunning() {
        let state = resolve(android: AndroidListing(
            devices: [Self.emulator, Self.phone, AndroidDevice(serial: "emulator-5556", state: .offline, model: nil)],
            avds: ["Medium_Phone", "Pixel_9", "Tablet"], bootingAVDs: ["Tablet"], note: nil
        ))
        #expect(state.androidRows.map(\.target) == [
            .android("emulator-5554"), .android("R5CT"), .android("avd:Pixel_9"), .android("avd:Tablet"),
        ])
        #expect(state.androidRows.map(\.title) == ["Medium Phone", "R5CT", "Pixel 9", "Tablet"])
        #expect(state.androidRows.map(\.detail) == ["Android 16", "Allow USB debugging", "Shut down", "Booting"])
        #expect(state.androidRows.map(\.tone) == [.live, .idle, .idle, .busy])
    }

    @Test func anAndroidDeviceAnAgentDrivesIsBusy() {
        let state = DevicesTabState.resolve(
            simulators: [Self.off], listError: nil, vms: [:], lastUsed: nil, bootingUDIDs: [],
            agentDriving: [.android("emulator-5554")],
            android: AndroidListing(devices: [Self.emulator], avds: [], bootingAVDs: [], note: nil)
        )
        #expect(state.androidRows.map(\.tone) == [.busy])
    }

    @Test func withoutTheSDKTheSectionShowsItsNote() {
        let note = "Install Android Studio or the SDK command-line tools to use Android devices"
        let state = resolve(android: AndroidListing(devices: [], avds: [], bootingAVDs: [], note: note))
        #expect(state.androidRows.isEmpty)
        #expect(state.androidNote == note)
    }

    @Test func theSimulatorsNoteSaysWhyThereAreNone() {
        let noXcode = DevicesTabState.resolve(
            simulators: nil, listError: "no simctl", vms: Self.stoppedVMs, lastUsed: nil, bootingUDIDs: [], agentDriving: []
        )
        #expect(noXcode.simulatorsNote == "Install Xcode to use iOS simulators")
        #expect(resolve(simulators: [], vms: Self.stoppedVMs, android: nil).simulatorsNote == "No iOS simulators")
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
        let row = resolve(vms: [.macOS: status], android: nil).vmRows.first
        #expect(row?.title == "macOS VM")
        #expect(row?.detail == detail)
        #expect(row?.tone == tone)
    }

    @Test func anAgentDrivingMakesARowBusy() {
        let state = DevicesTabState.resolve(
            simulators: [Self.on], listError: nil, vms: [.macOS: .running], lastUsed: nil,
            bootingUDIDs: [], agentDriving: [.simulator("on"), .vm(.macOS)]
        )
        #expect(state.simulatorRows.map(\.tone) == [.busy])
        #expect(state.vmRows.map(\.tone) == [.busy])
        #expect(state.simulatorRows.first?.detail == "iOS 26.5")
    }

    @Test(arguments: [
        (DevicesTarget.simulator("off"), "off"),
        (.simulator("gone"), "on"),
        (.vm(.macOS), "on"),
        (nil, "on"),
    ] as [(DevicesTarget?, String)])
    func aRunScriptsAppGoesToTheLastUsedSimulatorElseABootedOne(lastUsed: DevicesTarget?, udid: String) {
        #expect(SimulatorTarget.choose(lastUsed: lastUsed, simulators: [Self.off, Self.on])?.udid == udid)
    }

    @Test func withNothingBootedARunScriptsAppGoesToTheFirstSimulator() {
        #expect(SimulatorTarget.choose(lastUsed: nil, simulators: [Self.off])?.udid == "off")
        #expect(SimulatorTarget.choose(lastUsed: nil, simulators: []) == nil)
    }

    @Test func runningDevicesLeadAndLeaveTheirSections() {
        let state = resolve(
            simulators: [Self.off, Self.on], vms: [.macOS: .running, .linux: .stopped],
            android: AndroidListing(devices: [Self.emulator], avds: ["Medium_Phone", "Pixel_9"], bootingAVDs: [], note: nil)
        )
        let listing = state.switcherListing(query: "", showsOlderRuntimes: false)
        #expect(listing.sections.map(\.kind) == [.running, .runtime("iOS 26.5"), .android, .vms])
        #expect(listing.sections[0].rows.map(\.target) == [.simulator("on"), .android("emulator-5554"), .vm(.macOS)])
        #expect(listing.sections[1].rows.map(\.target) == [.simulator("off")])
    }

    @Test func olderRuntimesFoldUnlessLastUsedOrShown() {
        let sims = [Self.old, Self.off, Self.mid]
        let folded = resolve(simulators: sims, lastUsed: .simulator("off"), android: nil)
            .switcherListing(query: "", showsOlderRuntimes: false)
        #expect(folded.sections.map(\.kind) == [.runtime("iOS 26.5")])
        #expect(folded.foldedRuntimeCount == 2)

        let lastUsedOld = resolve(simulators: sims, lastUsed: .simulator("old"), android: nil)
            .switcherListing(query: "", showsOlderRuntimes: false)
        #expect(lastUsedOld.sections.map(\.kind) == [.runtime("iOS 26.5"), .runtime("iOS 18.6")])
        #expect(lastUsedOld.foldedRuntimeCount == 1)

        let shown = resolve(simulators: sims, android: nil).switcherListing(query: "", showsOlderRuntimes: true)
        #expect(shown.sections.map(\.kind) == [.runtime("iOS 26.5"), .runtime("iOS 26.0"), .runtime("iOS 18.6")])
        #expect(shown.foldedRuntimeCount == 0)
    }

    @Test(arguments: [
        ("16e", [DevicesTarget.simulator("old")]),
        ("ipad", [.simulator("mid")]),
        ("ios 18", [.simulator("old")]),
        ("android", [.android("emulator-5554"), .android("avd:Pixel_9")]),
        ("linux", [.vm(.linux)]),
        ("zzz", []),
    ])
    func theFilterMatchesEveryToken(query: String, expected: [DevicesTarget]) {
        let state = resolve(
            simulators: [Self.old, Self.off, Self.mid], vms: [.linux: .stopped],
            android: AndroidListing(devices: [Self.emulator], avds: ["Medium_Phone", "Pixel_9"], bootingAVDs: [], note: nil)
        )
        let listing = state.switcherListing(query: query, showsOlderRuntimes: false)
        #expect(listing.sections.flatMap(\.rows).map(\.target) == expected)
        #expect(listing.foldedRuntimeCount == 0)
    }

    @Test func notesShowOnlyWithoutAQuery() {
        let note = "Install Android Studio or the SDK command-line tools to use Android devices"
        let state = resolve(simulators: [], android: AndroidListing(devices: [], avds: [], bootingAVDs: [], note: note))
        let listing = state.switcherListing(query: "", showsOlderRuntimes: false)
        #expect(listing.sections.map(\.kind) == [.simulatorsNote, .android])
        #expect(listing.sections.map(\.note) == ["No iOS simulators", note])
        #expect(state.switcherListing(query: "x", showsOlderRuntimes: false).sections.isEmpty)
    }

    /// Booting and connected devices count; a USB phone waiting for approval stays, where its Retry is.
    @Test func runningDevicesStackSimulatorsThenAndroidThenVMsEachByName() {
        let zeta = SimulatorDevice(udid: "zeta", name: "iPhone Zeta", runtimeName: "iOS 26.5", state: .booted)
        let state = DevicesTabState.resolve(
            simulators: [zeta, Self.off, Self.on, Self.mid], listError: nil,
            vms: [.macOS: .running, .linux: .starting], lastUsed: nil, bootingUDIDs: ["off"], agentDriving: [],
            android: AndroidListing(
                devices: [Self.phone, Self.emulator], avds: ["Medium_Phone", "Pixel_9", "Tablet"],
                bootingAVDs: ["Tablet"], note: nil
            )
        )
        #expect(state.running.map(\.id) == [
            .simulator("off"), .simulator("on"), .simulator("zeta"),
            .android("emulator-5554"), .android("R5CT"), .android("avd:Tablet"),
            .vm(.linux), .vm(.macOS),
        ])
        #expect(state.running.first?.screen == .simulator(Self.off, .booting))
        #expect(state.running[4].screen == .android(
            AndroidTarget(id: "R5CT", title: "R5CT", device: Self.phone, avdName: nil), .unauthorized
        ))
        #expect(state.empty == nil)
    }

    @Test(arguments: [
        (VMDeviceStatus.running, true), (.starting, true), (.pausing, true),
        (.stopped, false), (.notCreated, false), (.paused(savedAt: .distantPast), false),
        (.runningElsewhere(label: "Alas Dev"), false),
    ] as [(VMDeviceStatus, Bool)])
    func onlyAVMRunningHereJoinsTheStack(status: VMDeviceStatus, stacked: Bool) {
        let state = resolve(vms: [.macOS: status], android: nil)
        #expect(state.running.map(\.id) == (stacked ? [.vm(.macOS)] : []))
    }

    @Test func withNothingRunningTheRailSaysWhyOrOffersADevice() {
        #expect(resolve(simulators: nil, android: nil).empty == .loading)
        let noXcode = DevicesTabState.resolve(
            simulators: nil, listError: "no simctl", vms: [:], lastUsed: nil, bootingUDIDs: [], agentDriving: []
        )
        #expect(noXcode.empty == .unavailable("no simctl"))
        #expect(resolve(simulators: [], android: nil).empty == .noSimulators)
        let simulator = resolve(simulators: [Self.off], vms: Self.stoppedVMs, android: nil)
        #expect(simulator.empty == .nothingRunning(suggested: simulator.simulatorRows.first))
        let vmOnly = DevicesTabState.resolve(
            simulators: nil, listError: "no simctl", vms: Self.stoppedVMs, lastUsed: nil, bootingUDIDs: [], agentDriving: []
        )
        #expect(vmOnly.empty == .nothingRunning(suggested: vmOnly.vmRows.first))
    }

    @Test func theLastUsedDeviceIsOfferedFirst() {
        let state = resolve(simulators: [Self.off, Self.mid], lastUsed: .simulator("mid"), android: nil)
        #expect(state.empty == .nothingRunning(suggested: state.simulatorRows.last))
    }
}
