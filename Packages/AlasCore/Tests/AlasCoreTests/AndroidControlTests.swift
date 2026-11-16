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

    /// An emulator whose AVD name couldn't be read last poll is asked again,
    /// even though its Android version is known.
    @Test func aMissingAVDNameIsLookedUpAgain() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("alas-adb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let adb = dir.appendingPathComponent("adb")
        try """
        #!/bin/sh
        case "$*" in
          "devices -l") printf 'List of devices attached\\nemulator-5554 device model:sdk_gphone64_arm64\\n' ;;
          *"emu avd name") printf 'Medium_Phone\\r\\nOK\\r\\n' ;;
          *) echo 16 ;;
        esac
        """.write(to: adb, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)
        let control = AndroidControl(sdk: AndroidSDK(root: nil, adb: adb.path, emulator: nil))
        let known = AndroidDevice(serial: "emulator-5554", state: .ready, model: "sdk_gphone64_arm64", release: "16")
        let devices = try await control.devices(known: ["emulator-5554": known])
        #expect(devices.first?.avdName == "Medium_Phone")
    }

    static let dump = Data(#"""
    <?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation="0">
    <node index="0" text="" resource-id="" class="android.widget.FrameLayout" package="p" content-desc="" checkable="false" clickable="false" enabled="true" password="false" bounds="[0,0][1080,2400]">
    <node index="0" text="Network &amp; internet" resource-id="android:id/title" class="android.widget.TextView" package="p" content-desc="" checkable="false" clickable="false" enabled="true" password="false" bounds="[189,420][651,483]" />
    <node index="1" text="" resource-id="p:id/save" class="android.widget.Button" package="p" content-desc="Save" checkable="false" clickable="true" enabled="false" password="false" bounds="[0,525][1080,630]" />
    <node index="2" text="hunter2" resource-id="p:id/pw" class="android.widget.EditText" package="p" content-desc="" checkable="false" clickable="true" enabled="true" password="true" bounds="[42,700][1038,826]" />
    <node index="3" text="" resource-id="" class="android.widget.ImageButton" package="p" content-desc="" checkable="false" clickable="true" enabled="true" password="false" bounds="[0,900][126,1026]" />
    </node></hierarchy>UI hierchary dumped to: /dev/tty
    """#.utf8)

    @Test func aUIDumpBecomesASnapshotInDP() throws {
        let snapshot = try AndroidUIDump.parse(Self.dump, density: 420, generation: 3)
        #expect(abs(snapshot.screenWidth - 1080.0 * 160 / 420) < 0.001)
        #expect(snapshot.elements.map(\.ref) == ["s3e1", "s3e2", "s3e3", "s3e4"])
        #expect(snapshot.elements.map(\.role) == ["text view", "button", "edit text", "image button"])
        #expect(snapshot.elements.map(\.label) == ["Network & internet", "Save", nil, nil])
        #expect(snapshot.elements.map(\.id) == ["android:id/title", "p:id/save", "p:id/pw", nil])
        #expect(snapshot.elements.map(\.isControl) == [false, true, true, true])
        #expect(snapshot.elements[1].enabled == false)
        #expect(abs(snapshot.elements[0].x - 189.0 * 160 / 420) < 0.001)
    }

    /// Android gives containers ids; a node with nothing to name and no action is noise.
    @Test func aContainerWithOnlyAnIDIsLeftOut() throws {
        let xml = Data(#"""
        <hierarchy rotation="0"><node class="android.widget.FrameLayout" text="" content-desc="" resource-id="" clickable="false" bounds="[0,0][1080,2400]">
        <node class="android.widget.ScrollView" text="" content-desc="" resource-id="p:id/content" clickable="false" bounds="[0,0][1080,2400]" />
        </node></hierarchy>
        """#.utf8)
        #expect(try AndroidUIDump.parse(xml, density: 420, generation: 1).elements.isEmpty)
    }

    @Test func aPasswordFieldsTextIsLeftOut() throws {
        let snapshot = try AndroidUIDump.parse(Self.dump, density: 420, generation: 1)
        #expect(!snapshot.json(query: nil, limit: 200).contains("hunter2"))
    }

    @Test(arguments: [("1.0", SimulatorReadBack.value(SimulatorTextSize.large)), ("2.0", .value(.accessibilityExtraExtraExtraLarge)),
                      ("1.15", .unknown), ("nonsense", .unknown)])
    func fontScaleReadsBackThroughTheTable(scale: String, size: SimulatorReadBack<SimulatorTextSize>) {
        #expect(AndroidFontScale.textSize(for: scale) == size)
    }

    @Test func everyTextSizeHasItsOwnScale() {
        let scales = SimulatorTextSize.allCases.map(AndroidFontScale.scale(for:))
        #expect(Set(scales).count == SimulatorTextSize.allCases.count)
        #expect(AndroidFontScale.scale(for: .large) == 1.0)
    }

    @Test(arguments: [
        (SimulatorPrivacyService.microphone, ["android.permission.RECORD_AUDIO"] as [String]?),
        (.location, ["android.permission.ACCESS_FINE_LOCATION", "android.permission.ACCESS_COARSE_LOCATION"]),
        (.siri, nil), (.photosAdd, nil),
    ])
    func privacyServicesMapToRuntimePermissions(service: SimulatorPrivacyService, permissions: [String]?) {
        #expect(AndroidPermissions.permissions(for: service) == permissions)
    }

    @Test func logcatLinesParseWithTheirLevel() {
        let lines = AndroidLogcat.parse("""
        --------- beginning of main
        11-16 09:39:53.715  9147  9294 D PrefCtrl: Could not find
        11-16 09:39:54.465  9147  9294 E Binder  : failed: code 1
        """, year: 2026)
        #expect(lines.map(\.level) == ["Debug", "Error"])
        #expect(lines.map(\.pid) == [9147, 9147])
        #expect(lines[1].process == "Binder")
        #expect(lines[1].message == "failed: code 1")
        #expect(lines[0].time == "2026-11-16 09:39:53.715")
    }

    @Test func theFrontAppComesFromTheResumedActivity() {
        #expect(AndroidLogcat.frontmostPackage(
            "  topResumedActivity=ActivityRecord{1 u0 com.android.settings/.homepage.SettingsHomepageActivity t7}"
        ) == "com.android.settings")
        #expect(AndroidLogcat.frontmostPackage("nothing") == nil)
    }

    @Test(arguments: [("8CA9B1E8-EE67-49E5-846F-293450990F76", true), ("emulator-5554", false), ("avd:Pixel_9", false)])
    func simulatorIDsAreUUIDs(id: String, isSimulator: Bool) {
        #expect(AgentDevice.isSimulatorID(id) == isSimulator)
    }

    @Test func javaCrashesAreReadForTheirPackageOnly() {
        let lines = AndroidLogcat.parse("""
        11-16 10:01:02.100  4242  4242 E AndroidRuntime: FATAL EXCEPTION: main
        11-16 10:01:02.100  4242  4242 E AndroidRuntime: Process: com.example.hello, PID: 4242
        11-16 10:01:02.100  4242  4242 E AndroidRuntime: java.lang.IllegalStateException: boom
        11-16 10:01:02.100  4242  4242 E AndroidRuntime: \tat com.example.hello.Main.onCreate(Main.kt:12)
        11-16 10:01:02.100  4242  4242 E AndroidRuntime: \tat android.app.Activity.performCreate(Activity.java:9000)
        11-16 10:05:00.000  5000  5000 E AndroidRuntime: FATAL EXCEPTION: main
        11-16 10:05:00.000  5000  5000 E AndroidRuntime: Process: com.other, PID: 5000
        11-16 10:05:00.000  5000  5000 E AndroidRuntime: java.lang.RuntimeException: other
        """, year: 2026)
        let crashes = AndroidLogcat.crashes(lines, package: "com.example.hello")
        #expect(crashes == [AndroidCrash(
            package: "com.example.hello", time: "2026-11-16 10:01:02.100", exception: "java.lang.IllegalStateException: boom",
            frames: ["com.example.hello.Main.onCreate(Main.kt:12)", "android.app.Activity.performCreate(Activity.java:9000)"]
        )])
        // All Processes: every package's crashes, each naming its package.
        #expect(AndroidLogcat.crashes(lines, package: nil).map(\.package) == ["com.example.hello", "com.other"])
    }

    @Test func malformedBoundsDropTheNodeAndEntitiesDecode() throws {
        let xml = Data(#"""
        <hierarchy rotation="0"><node class="android.widget.FrameLayout" text="" bounds="[0,0][1080,2400]">
        <node class="android.widget.Button" text="Bad" clickable="true" bounds="[0,0][100,oops][200]" />
        <node class="android.widget.Button" text="Tom &amp; &quot;Jerry&quot; &#233;" clickable="true" bounds="[0,0][160,160]" />
        </node></hierarchy>
        """#.utf8)
        let snapshot = try AndroidUIDump.parse(xml, density: 160, generation: 1)
        #expect(snapshot.elements.map(\.label) == ["Tom & \"Jerry\" é"])
    }

    @Test(arguments: [
        ("  mCurrentOrientation=2\n  mCurrentOrientation=0", 2 as Int?), ("mCurrentOrientation=1", 1), ("nothing", nil),
    ])
    func theDisplaysActualRotationIsRead(output: String, rotation: Int?) {
        #expect(AndroidRotation.parseDisplay(output) == rotation)
    }

    /// The first node can be a dialog's window, not the display: the screen comes from the display's size.
    @Test(arguments: [("0", 1080.0, 2400.0), ("1", 2400.0, 1080.0)])
    func theScreenIsTheDisplayTurnedByTheDumpsRotation(rotation: String, width: Double, height: Double) throws {
        let xml = Data("""
        <hierarchy rotation="\(rotation)"><node class="android.widget.FrameLayout" text="" bounds="[100,500][980,1500]">
        <node class="android.widget.Button" text="OK" clickable="true" bounds="[500,1300][900,1450]" />
        </node></hierarchy>
        """.utf8)
        let snapshot = try AndroidUIDump.parse(xml, density: 160, displaySize: (1080, 2400), generation: 1)
        #expect(snapshot.screenWidth == width && snapshot.screenHeight == height)
        #expect(snapshot.elements.map(\.label) == ["OK"])
    }

    @Test(arguments: [("Physical size: 1080x2400\n", 1080.0, 2400.0), ("Physical size: 1080x2400\nOverride size: 720x1600", 720, 1600)])
    func theDisplaySizePrefersAnOverride(output: String, width: Double, height: Double) {
        let size = AndroidUIDump.displaySize(output)
        #expect(size?.width == width && size?.height == height)
    }

    @Test(arguments: [("Wifi is enabled\nWifi scanning…", SimulatorReadBack<Bool>.value(true)), ("Wifi is disabled", .value(false)), ("", .unknown)])
    func wifiReadsFromItsStatus(status: String, expected: SimulatorReadBack<Bool>) {
        #expect(AndroidNetwork.wifi(status) == expected)
    }

    @Test(arguments: [("1\n", SimulatorReadBack<Bool>.value(true)), ("0", .value(false)), ("null", .unknown)])
    func mobileDataReadsFromItsSetting(setting: String, expected: SimulatorReadBack<Bool>) {
        #expect(AndroidNetwork.data(setting) == expected)
    }

    @Test(arguments: [
        (nil as Int?, 42 as Int?, AndroidLogFollow.restart(pid: 42)),
        (42, 42, .keep),
        (42, 43, .restart(pid: 43)),
        (42, nil, .waitForApp),
        (nil, nil, .waitForApp),
    ])
    func followingAnAppRestartsOnANewPID(running: Int?, found: Int?, next: AndroidLogFollow) {
        #expect(AndroidLogFollow.next(running: running, found: found) == next)
    }

    @Test func aCrashBecomesACrashReport() {
        let crash = AndroidCrash(package: "com.example.hello", time: "2026-11-16 10:01:02.100", exception: "java.lang.X: boom", frames: ["a.B.c(B.kt:1)"])
        let report = crash.report()
        #expect(report.exception == "java.lang.X: boom")
        #expect(report.frames == ["a.B.c(B.kt:1)"])
        #expect(Calendar(identifier: .gregorian).component(.second, from: report.capturedAt) == 2)
    }

    /// The Logs tab tells crashes apart by their report: the same stack twice is two crashes.
    @Test func twoCrashesAtTheSameStackAreTwoReports() {
        let first = AndroidCrash(package: "p", time: "2026-11-16 10:01:02.100", exception: "java.lang.X: boom", frames: ["a.B.c(B.kt:1)"])
        let again = AndroidCrash(package: "p", time: "2026-11-16 10:05:00.000", exception: "java.lang.X: boom", frames: ["a.B.c(B.kt:1)"])
        #expect(first.report().report != again.report().report)
    }
}
