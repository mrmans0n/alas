import Foundation
import Testing
import AlasCore

struct AndroidControlTests {
    @Test(arguments: [
        // ANDROID_HOME wins over ANDROID_SDK_ROOT and the default location.
        (["ANDROID_HOME": "/h", "ANDROID_SDK_ROOT": "/r"], ["/h/platform-tools/adb", "/r/platform-tools/adb"], "/h"),
        (["ANDROID_SDK_ROOT": "/r"], ["/r/platform-tools/adb", "/u/Library/Android/sdk/platform-tools/adb"], "/r"),
        ([:], ["/u/Library/Android/sdk/platform-tools/adb"], "/u/Library/Android/sdk"),
        // A root without adb is skipped.
        (["ANDROID_HOME": "/h"], ["/u/Library/Android/sdk/platform-tools/adb"], "/u/Library/Android/sdk"),
    ] as [([String: String], [String], String)])
    func theSDKIsFoundInOrder(environment: [String: String], executables: [String], root: String) {
        let sdk = AndroidSDK.locate(environment: environment, home: "/u", isExecutable: executables.contains)
        #expect(sdk?.root == root)
        #expect(sdk?.adb == root + "/platform-tools/adb")
    }

    @Test func withoutAnSDKRootAdbOnThePathStillCounts() {
        let sdk = AndroidSDK.locate(
            environment: ["PATH": "/usr/bin:/opt/tools"], home: "/u", isExecutable: { $0 == "/opt/tools/adb" }
        )
        #expect(sdk == AndroidSDK(root: nil, adb: "/opt/tools/adb", emulator: nil))
        #expect(AndroidSDK.locate(environment: [:], home: "/u", isExecutable: { _ in false }) == nil)
    }

    @Test func theNewestBuildToolsAreChosenByVersion() {
        #expect(AndroidSDK.newestBuildTools(["34.0.0", "36.1.0", "36.0.0", "9.0.0"]) == "36.1.0")
        #expect(AndroidSDK.newestBuildTools([]) == nil)
    }

    @Test func adbDevicesListsEachDeviceWithItsState() {
        let output = """
        * daemon not running; starting now at tcp:5037
        * daemon started successfully
        List of devices attached
        emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:4
        R5CT1234ABC            unauthorized usb:1-1 transport_id:5
        0A1B2C3D               offline transport_id:6
        9C2X                   device usb:2-1 product:komodo model:Pixel_9_Pro device:komodo transport_id:7

        """
        #expect(AndroidDevice.parseList(output) == [
            AndroidDevice(serial: "emulator-5554", state: .ready, model: "sdk_gphone64_arm64"),
            AndroidDevice(serial: "R5CT1234ABC", state: .unauthorized, model: nil),
            AndroidDevice(serial: "0A1B2C3D", state: .offline, model: nil),
            AndroidDevice(serial: "9C2X", state: .ready, model: "Pixel_9_Pro"),
        ])
    }

    @Test func avdNamesSkipTheEmulatorsLogLines() {
        #expect(AndroidDevice.parseAVDs("INFO    | Storing crashdata in: /tmp/x\nMedium_Phone_API_36.1\nPixel_9\n\n")
            == ["Medium_Phone_API_36.1", "Pixel_9"])
        #expect(AndroidDevice.parseAVDName("Medium_Phone_API_36.1\r\nOK\r\n") == "Medium_Phone_API_36.1")
        #expect(AndroidDevice.parseAVDName("OK\r\n") == nil)
    }

    @Test(arguments: [
        (AndroidDevice(serial: "emulator-5554", state: .ready, model: "sdk_gphone64_arm64", avdName: "Medium_Phone_API_36.1"),
         "Medium Phone API 36.1"),
        (AndroidDevice(serial: "9C2X", state: .ready, model: "Pixel_9_Pro"), "Pixel 9 Pro"),
        (AndroidDevice(serial: "R5CT1234ABC", state: .unauthorized, model: nil), "R5CT1234ABC"),
    ])
    func aDeviceIsTitledByItsAVDThenModelThenSerial(device: AndroidDevice, title: String) {
        #expect(device.title == title)
    }

    @Test(arguments: [("lock 0\n", 0), ("lock 3", 3), ("free\n", 0), ("nonsense", 0)])
    func rotationIsReadFromTheWindowManager(output: String, rotation: Int) {
        #expect(AndroidRotation.parse(output) == rotation)
    }

    @Test(arguments: [(0, true, 1), (3, true, 0), (0, false, 3), (1, false, 0)])
    func turningLeftAddsAQuarterTurn(rotation: Int, left: Bool, turned: Int) {
        #expect(AndroidRotation.turned(rotation, left: left) == turned)
    }

    @Test func aapt2NamesThePackage() {
        #expect(AndroidAPK.parsePackageName("com.example.hello\n") == "com.example.hello")
        #expect(AndroidAPK.parsePackageName("W/ziparchive: Unable to open\n") == nil)
    }
}
