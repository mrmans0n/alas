import AlasCore
import Foundation
import Testing

struct SimulatorDeviceListTests {
    @Test func listsAvailableIOSDevicesBootedFirstThenNewestRuntimeThenName() throws {
        let json = """
        {"devices": {
          "com.apple.CoreSimulator.SimRuntime.iOS-26-1": [
            {"udid": "A", "name": "iPhone 17 Pro", "state": "Shutdown", "isAvailable": true},
            {"udid": "B", "name": "iPhone Air", "state": "Booted", "isAvailable": true,
             "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-Air"}
          ],
          "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
            {"udid": "C", "name": "iPhone 17", "state": "Shutdown", "isAvailable": true},
            {"udid": "D", "name": "iPad Pro", "state": "Shutdown", "isAvailable": true},
            {"udid": "E", "name": "iPhone 16", "state": "Shutdown", "isAvailable": false}
          ],
          "com.apple.CoreSimulator.SimRuntime.watchOS-26-0": [
            {"udid": "F", "name": "Apple Watch", "state": "Booted", "isAvailable": true}
          ]
        }}
        """
        let devices = try SimulatorDeviceList.parse(Data(json.utf8))
        #expect(devices.map(\.udid) == ["B", "D", "C", "A"])
        #expect(devices[0] == SimulatorDevice(
            udid: "B", name: "iPhone Air", runtimeName: "iOS 26.1", state: .booted,
            deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-Air"
        ))
    }

    @Test func runtimeVersionsCompareAsNumbers() throws {
        let json = """
        {"devices": {
          "com.apple.CoreSimulator.SimRuntime.iOS-26-9": [
            {"udid": "old", "name": "iPhone", "state": "Shutdown", "isAvailable": true}
          ],
          "com.apple.CoreSimulator.SimRuntime.iOS-26-10": [
            {"udid": "new", "name": "iPhone", "state": "Shutdown", "isAvailable": true}
          ]
        }}
        """
        #expect(try SimulatorDeviceList.parse(Data(json.utf8)).map(\.udid) == ["new", "old"])
    }

    @Test(arguments: [
        ("iPhone-17-Pro", true), ("iPhone-Air", true), ("iPhone-15", true), ("iPhone-14-Pro-Max", true),
        ("iPhone-18-Pro", true), ("iPhone-17e", false), ("iPhone-16e", false), ("iPhone-14", false),
        ("iPhone-14-Plus", false), ("iPhone-13-mini", false), ("iPhone-SE-3rd-generation", false),
        ("iPhone-Duo", false), ("iPad-Pro-11-inch-M5", false),
    ])
    func knowsWhichIPhonesHaveADynamicIsland(model: String, expected: Bool) {
        let device = SimulatorDevice(udid: "A", name: model, runtimeName: "iOS 26.4", state: .booted,
                                     deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType." + model)
        #expect(device.hasDynamicIsland == expected)
    }
}
