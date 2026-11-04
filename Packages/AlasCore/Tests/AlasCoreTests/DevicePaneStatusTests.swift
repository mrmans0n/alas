import AlasCore
import Testing

struct DevicePaneStatusTests {
    static let off = SimulatorDevice(udid: "off", name: "iPhone 17", runtimeName: "iOS 26.5", state: .shutdown)
    static let on = SimulatorDevice(udid: "on", name: "iPhone Air", runtimeName: "iOS 26.5", state: .booted)

    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        var devices: [SimulatorDevice]? = [off, on]
        var listError: String? = nil
        var selected: String? = nil
        var booting: Set<String> = []
        let expected: DevicePaneStatus
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "simctl error", listError: "xcrun: error: unable to find utility \"simctl\"",
             expected: .unavailable("xcrun: error: unable to find utility \"simctl\"")),
        Case(name: "not listed yet", devices: nil, expected: .loading),
        Case(name: "no simulators", devices: [], expected: .noDevices),
        Case(name: "no choice picks the first booted", expected: .streaming(on)),
        Case(name: "no choice and nothing booted", devices: [off], expected: .choose),
        Case(name: "shut down outside Alas stays chosen", selected: "off", expected: .shutDown(off)),
        Case(name: "deleted choice falls back to the first booted", selected: "gone", expected: .streaming(on)),
        Case(name: "booting before simctl says so", selected: "off", booting: ["off"], expected: .booting(off)),
    ]

    @Test(arguments: cases)
    func statusFollowsTheDeviceListAndTheChoice(_ c: Case) {
        let status = DevicePaneStatus.resolve(
            devices: c.devices, listError: c.listError, selectedUDID: c.selected, bootingUDIDs: c.booting
        )
        #expect(status == c.expected)
    }
}
