# Devices: Android in the Devices tab — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Android emulators and connected phones appear in the Devices tab; the user boots an AVD, sees its screen live and drives it with the mouse and keyboard, with rotate, ⌘C/⌘V, screenshot, recording and `.apk` drop.

**Architecture:** AlasCore holds everything that doesn't touch the OS's UI or video stack: SDK discovery, `adb`/`emulator` commands and their parsing, the scrcpy wire format (stream parser, control encoders, device messages), H.264 Annex B handling, the key table, and the Devices tab's Android rows and stages. The app runs one scrcpy server per watched device (`AndroidStreamClient`), decodes H.264 with VideoToolbox into IOSurface-backed frames, and shows them through the same `DeviceScreenView` as simulators via a `DeviceScreenSource` protocol. `DeviceStage`'s frame and gutter are extracted so the Android stage reuses them.

**Tech Stack:** Swift 5.9, SwiftUI/AppKit, Network.framework (`NWConnection`), VideoToolbox, Swift Testing, bash build scripts, xcodegen.

**Spec:** `docs/plans/2026-11-15-devices-android-design.md`

## Global Constraints

- English only; Conventional Commits; no agent attribution.
- AlasCore must not import AppKit, SwiftUI, VideoToolbox or Network; anything the app uses from it is `public`. `swift test --package-path Packages/AlasCore` must keep working.
- After adding app files or editing `project.yml`, run `xcodegen`. Commit `project.yml` with the regenerated pbxproj; for new app files only, commit just the new-file hunks of the pbxproj (`git diff -U0` → keep matching hunks → `git checkout` the pbxproj → `git apply --unidiff-zero`).
- `swiftformat Alas AlasTests Packages --lint` must pass: no semicolons.
- Tests: Swift Testing, extend existing suites, parameterize variants, no fixed sleeps.
- scrcpy: server `scrcpy-server-v5.0.1`, SHA-256 `764eb6f79811d5211fe9df341120882ba9994c7a61b897d7bf3fb662e53bc536`, client version argument `5.0.1`, bundled at `Contents/Resources/scrcpy/scrcpy-server` with `Contents/Resources/scrcpy/LICENSE`.
- Device path of the pushed server: `/data/local/tmp/alas-scrcpy-server.jar`.
- Server arguments: `scid=<8 hex digits> tunnel_forward=true audio=false control=true max_size=1600 clipboard_autosync=false`.
- `DevicesTarget.android(String)`: a serial (`emulator-5554`, `R5CT…`) or `avd:<name>` for an AVD that isn't running.
- Copy: SDK missing — "Install Android Studio or the SDK command-line tools to use Android devices"; unauthorized — "Allow USB debugging on the phone"; no build-tools — "Installed; open it from the launcher."

## Review Focus

1. **An AVD that boots while selected**: its target changes from `avd:<name>` to `emulator-NNNN`; the selection must follow, not fall back to another device. Task 4 tests it.
2. **A session size change mid-drag (rotation)**: touches must use the newest session size, or scrcpy drops them. Task 6's client reads the size at send time; Task 2 tests the parser emits each session packet.
3. **Partial reads**: a frame header or payload split across socket reads, and several packets in one read. Task 2's parser test feeds byte by byte and all at once.
4. **A Mac with the Android SDK but no Xcode**: Android must list and stream even though simulator polling never starts. Task 7 gives Android its own poll gate.
5. **A server left from a crashed session or another scrcpy**: starting a stream kills `com.genymobile.scrcpy.Server` processes first and pushes the jar every time (cleanup deletes it). Task 6 does both; the end-to-end pass in Task 9 restarts a stream after killing the client.

---

### Task 1: Android SDK and device commands (AlasCore)

**Files:**
- Create: `Packages/AlasCore/Sources/AlasFeatures/Devices/Android/AndroidSDK.swift`
- Create: `Packages/AlasCore/Sources/AlasFeatures/Devices/Android/AndroidDevice.swift`
- Create: `Packages/AlasCore/Sources/AlasFeatures/Devices/Android/AndroidControl.swift`
- Test: create `Packages/AlasCore/Tests/AlasCoreTests/AndroidControlTests.swift`

**Interfaces:**
- Produces:
  - `public struct AndroidSDK: Equatable, Sendable { public let root: String?; public let adb: String; public let emulator: String?; public static func locate(environment: [String: String], home: String, isExecutable: (String) -> Bool) -> AndroidSDK?; public static func newestBuildTools(_ versions: [String]) -> String? }`
  - `public struct AndroidDevice: Equatable, Sendable { public enum State { case ready, unauthorized, offline }; public let serial: String; public let state: State; public let model: String?; public var avdName: String?; public var release: String?; public var isEmulator: Bool; public var title: String; public static func parseList(_ output: String) -> [AndroidDevice]; public static func parseAVDs(_ output: String) -> [String]; public static func parseAVDName(_ output: String) -> String? }`
  - `public enum AndroidRotation { public static func parse(_ output: String) -> Int; public static func turned(_ rotation: Int, left: Bool) -> Int }`
  - `public enum AndroidAPK { public static func parsePackageName(_ output: String) -> String? }`
  - `public struct AndroidControlError: Error, Equatable, LocalizedError { public let message: String }`
  - `public struct AndroidControl: Sendable { public let sdk: AndroidSDK; public init(sdk:); devices() async throws -> [AndroidDevice]; avds() async throws -> [String]; launchEmulator(avd: String, log: URL) throws -> Process; waitForBoot(avd: String, emulator: Process, log: URL, timeout: Duration) async throws -> String; kill(serial:) async throws; screenshot(serial:) async throws -> Data; install(serial:apk:) async throws; packageName(apk:) async -> String?; launch(serial:package:) async throws; rotation(serial:) async throws -> Int; setRotation(serial:_:) async throws; adb(_ serial: String?, _ args: [String], timeout: TimeInterval) async throws -> String }`

- [ ] **Step 1: Write the failing tests**

```swift
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
```

- [ ] **Step 2: Run them to see them fail**

`swift test --package-path Packages/AlasCore --filter AndroidControlTests` → build errors (types missing).

- [ ] **Step 3: Implement `AndroidSDK.swift`**

```swift
import Foundation

/// Where the user's Android SDK tools are. Alas never installs them.
public struct AndroidSDK: Equatable, Sendable {
    /// The SDK directory; nil when only `adb` on the PATH was found.
    public let root: String?
    public let adb: String
    public let emulator: String?

    public init(root: String?, adb: String, emulator: String?) {
        self.root = root
        self.adb = adb
        self.emulator = emulator
    }

    /// `$ANDROID_HOME`, then `$ANDROID_SDK_ROOT`, then `~/Library/Android/sdk`,
    /// the first holding `platform-tools/adb`; else `adb` and `emulator` on the PATH.
    public static func locate(environment: [String: String], home: String, isExecutable: (String) -> Bool) -> AndroidSDK? {
        let roots = [environment["ANDROID_HOME"], environment["ANDROID_SDK_ROOT"], home + "/Library/Android/sdk"]
            .compactMap { $0 }.filter { !$0.isEmpty }
        for root in roots where isExecutable(root + "/platform-tools/adb") {
            let emulator = root + "/emulator/emulator"
            return AndroidSDK(root: root, adb: root + "/platform-tools/adb", emulator: isExecutable(emulator) ? emulator : nil)
        }
        let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        guard let adb = path.map({ $0 + "/adb" }).first(where: isExecutable) else { return nil }
        return AndroidSDK(root: nil, adb: adb, emulator: path.map { $0 + "/emulator" }.first(where: isExecutable))
    }

    /// The live process's SDK.
    public static func locate() -> AndroidSDK? {
        locate(
            environment: ProcessInfo.processInfo.environment, home: NSHomeDirectory(),
            isExecutable: FileManager.default.isExecutableFile(atPath:)
        )
    }

    /// The highest build-tools version, compared number by number.
    public static func newestBuildTools(_ versions: [String]) -> String? {
        versions.max { lhs, rhs in
            let l = lhs.split(separator: ".").map { Int($0) ?? 0 }
            let r = rhs.split(separator: ".").map { Int($0) ?? 0 }
            return l.lexicographicallyPrecedes(r)
        }
    }

    /// `aapt2` from the newest build-tools, when the SDK has any.
    public var aapt2: String? {
        guard let root else { return nil }
        let dir = root + "/build-tools"
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        guard let newest = Self.newestBuildTools(versions) else { return nil }
        let tool = "\(dir)/\(newest)/aapt2"
        return FileManager.default.isExecutableFile(atPath: tool) ? tool : nil
    }
}
```

- [ ] **Step 4: Implement `AndroidDevice.swift`**

```swift
import Foundation

/// A device `adb` lists: an emulator or a connected phone.
public struct AndroidDevice: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case ready
        /// The phone hasn't allowed this Mac's USB debugging key yet.
        case unauthorized
        case offline
    }

    public let serial: String
    public let state: State
    /// `adb`'s `model:` field, underscores and all.
    public let model: String?
    /// The AVD a running emulator was started from.
    public var avdName: String?
    /// The Android version, such as "16", once read.
    public var release: String?

    public init(serial: String, state: State, model: String?, avdName: String? = nil, release: String? = nil) {
        self.serial = serial
        self.state = state
        self.model = model
        self.avdName = avdName
        self.release = release
    }

    public var isEmulator: Bool { serial.hasPrefix("emulator-") }

    /// The AVD's name, else the model, else the serial, with spaces for underscores.
    public var title: String {
        (avdName ?? model ?? serial).replacingOccurrences(of: "_", with: " ")
    }

    /// From `adb devices -l`.
    public static func parseList(_ output: String) -> [AndroidDevice] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2, !line.hasPrefix("*"), !line.hasPrefix("List of devices") else { return nil }
            let state: State = switch fields[1] {
            case "device": .ready
            case "unauthorized", "authorizing": .unauthorized
            default: .offline
            }
            let model = fields.dropFirst(2).first { $0.hasPrefix("model:") }.map { String($0.dropFirst("model:".count)) }
            return AndroidDevice(serial: fields[0], state: state, model: model)
        }
    }

    /// From `emulator -list-avds`, which may print log lines first.
    public static func parseAVDs(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { line in
            !line.isEmpty && line.allSatisfy { $0.isLetter || $0.isNumber || "._-".contains($0) }
        }
    }

    /// From `adb -s emulator-NNNN emu avd name`: the name, then "OK".
    public static func parseAVDName(_ output: String) -> String? {
        let first = output.split(whereSeparator: \.isNewline).first?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first, !first.isEmpty, first != "OK" else { return nil }
        return first
    }
}

/// The window manager's user rotation: 0 natural, 1 a quarter turn left, and so on.
public enum AndroidRotation {
    /// From `cmd window user-rotation`: "lock <n>", or "free" (taken as 0).
    public static func parse(_ output: String) -> Int {
        let words = output.split(whereSeparator: \.isWhitespace)
        guard words.count == 2, words[0] == "lock", let value = Int(words[1]), (0...3).contains(value) else { return 0 }
        return value
    }

    public static func turned(_ rotation: Int, left: Bool) -> Int {
        (rotation + (left ? 1 : 3)) % 4
    }
}

public enum AndroidAPK {
    /// From `aapt2 dump packagename <apk>`.
    public static func parsePackageName(_ output: String) -> String? {
        let line = output.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) }
        guard let line, line.contains("."),
              line.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" }) else { return nil }
        return line
    }
}
```

- [ ] **Step 5: Implement `AndroidControl.swift`**

```swift
import AlasPlatform
import Foundation

public struct AndroidControlError: Error, Equatable, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    init(_ result: ProcessResult, _ fallback: String) {
        let text = (result.stderr.isEmpty ? result.stdout : result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        message = text.isEmpty ? fallback : text
    }
    public var errorDescription: String? { message }
}

/// `adb` and `emulator` commands for the Devices tab.
public struct AndroidControl: Sendable {
    public let sdk: AndroidSDK

    public init(sdk: AndroidSDK) {
        self.sdk = sdk
    }

    /// Runs `adb [-s serial] args` and returns stdout.
    public func adb(_ serial: String?, _ args: [String], timeout: TimeInterval = Process.defaultTimeout) async throws -> String {
        let result = try await Process.run(sdk.adb, args: (serial.map { ["-s", $0] } ?? []) + args, timeout: timeout)
        guard result.exitCode == 0 else { throw AndroidControlError(result, "adb exited with status \(result.exitCode)") }
        return result.stdout
    }

    /// Connected devices, with each emulator's AVD and each ready device's Android version.
    public func devices() async throws -> [AndroidDevice] {
        var devices = AndroidDevice.parseList(try await adb(nil, ["devices", "-l"]))
        for index in devices.indices where devices[index].state == .ready {
            let serial = devices[index].serial
            if devices[index].isEmulator {
                devices[index].avdName = (try? await adb(serial, ["emu", "avd", "name"])).flatMap(AndroidDevice.parseAVDName)
            }
            devices[index].release = (try? await adb(serial, ["shell", "getprop", "ro.build.version.release"]))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return devices
    }

    public func avds() async throws -> [String] {
        guard let emulator = sdk.emulator else { return [] }
        let result = try await Process.run(emulator, args: ["-list-avds"])
        guard result.exitCode == 0 else { throw AndroidControlError(result, "emulator exited with status \(result.exitCode)") }
        return AndroidDevice.parseAVDs(result.stdout)
    }

    /// Starts an AVD with no window; it outlives Alas, as simulators do.
    public func launchEmulator(avd: String, log: URL) throws -> Process {
        guard let emulator = sdk.emulator else { throw AndroidControlError("The Android emulator isn't installed.") }
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: emulator)
        process.arguments = ["-avd", avd, "-no-window", "-no-audio", "-no-boot-anim"]
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        return process
    }

    /// Waits until the emulator started from `avd` has booted, and returns its serial.
    public func waitForBoot(avd: String, emulator: Process, log: URL, timeout: Duration = .seconds(180)) async throws -> String {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            guard emulator.isRunning else { throw AndroidControlError(Self.tail(of: log) ?? "The emulator quit while booting.") }
            if let device = try? await devices().first(where: { $0.avdName == avd && $0.state == .ready }),
               (try? await adb(device.serial, ["shell", "getprop", "sys.boot_completed"]))?
                   .trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
                return device.serial
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw AndroidControlError("The emulator didn't finish booting in 3 minutes.")
    }

    /// The last lines of an emulator's log, for a failed boot.
    static func tail(of log: URL, lines: Int = 5) -> String? {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return nil }
        let last = text.split(whereSeparator: \.isNewline).suffix(lines).joined(separator: "\n")
        return last.isEmpty ? nil : last
    }

    public func kill(serial: String) async throws {
        _ = try await adb(serial, ["emu", "kill"])
    }

    public func screenshot(serial: String) async throws -> Data {
        let result = try await Process.runData(sdk.adb, args: ["-s", serial, "exec-out", "screencap", "-p"], timeout: 30)
        guard result.exitCode == 0, !result.stdout.isEmpty else {
            throw AndroidControlError(result.stderr.isEmpty ? "The screenshot failed." : result.stderr)
        }
        return result.stdout
    }

    public func install(serial: String, apk: URL) async throws {
        _ = try await adb(serial, ["install", "-r", "-t", apk.path], timeout: 180)
    }

    /// The APK's package, when the SDK has build-tools.
    public func packageName(apk: URL) async -> String? {
        guard let aapt2 = sdk.aapt2,
              let result = try? await Process.run(aapt2, args: ["dump", "packagename", apk.path]),
              result.exitCode == 0 else { return nil }
        return AndroidAPK.parsePackageName(result.stdout)
    }

    public func launch(serial: String, package: String) async throws {
        _ = try await adb(serial, ["shell", "monkey", "-p", package, "-c", "android.intent.category.LAUNCHER", "1"])
    }

    public func rotation(serial: String) async throws -> Int {
        AndroidRotation.parse(try await adb(serial, ["shell", "cmd", "window", "user-rotation"]))
    }

    public func setRotation(serial: String, _ rotation: Int) async throws {
        _ = try await adb(serial, ["shell", "cmd", "window", "user-rotation", "lock", String(rotation)])
    }
}
```

- [ ] **Step 6: Run the tests**

`swift test --package-path Packages/AlasCore --filter AndroidControlTests` → all pass.

- [ ] **Step 7: Commit**

```bash
git add Packages/AlasCore/Sources/AlasFeatures/Devices/Android Packages/AlasCore/Tests/AlasCoreTests/AndroidControlTests.swift
git commit -m "feat(android): find the SDK and list, boot and drive Android devices with adb"
```

---

### Task 2: scrcpy wire format, H.264 and keys (AlasCore)

**Files:**
- Create: `Packages/AlasCore/Sources/AlasFeatures/Devices/Android/Scrcpy.swift`
- Create: `Packages/AlasCore/Sources/AlasFeatures/Devices/Android/H264AnnexB.swift`
- Create: `Packages/AlasCore/Sources/AlasFeatures/Devices/Android/AndroidKeys.swift`
- Test: create `Packages/AlasCore/Tests/AlasCoreTests/ScrcpyTests.swift`

**Interfaces:**
- Produces:
  - `public enum ScrcpyVideoEvent: Equatable, Sendable { case session(width: Int, height: Int), config(Data), frame(Data, keyFrame: Bool) }`
  - `public struct ScrcpyVideoParser: Sendable { public init(); public mutating func feed(_ data: Data) throws -> [ScrcpyVideoEvent] }` — expects the codec id first; throws `ScrcpyError.unsupportedCodec(UInt32)` for anything but H.264.
  - `public enum ScrcpyControl` with `keycode(_:keycode:repeat:metastate:)`, `touch(_:x:y:width:height:pointerID:pressure:actionButton:buttons:)`, `scroll(x:y:width:height:horizontal:vertical:buttons:)`, `backOrScreenOn(_:)`, `getClipboard(copy:)`, `setClipboard(sequence:text:paste:)`; nested `KeyAction`, `TouchAction`; constant `fingerPointerID: UInt64`.
  - `public enum ScrcpyDeviceMessage: Equatable, Sendable { case clipboard(String), ackClipboard(UInt64), uhidOutput(id: UInt16, data: Data) }` and `public struct ScrcpyDeviceMessageParser { public mutating func feed(_ data: Data) throws -> [ScrcpyDeviceMessage] }`
  - `public enum H264AnnexB { public static func nalUnits(_ data: Data) -> [Data]; public static func parameterSets(_ config: Data) -> (sps: Data, pps: Data)?; public static func avcc(_ data: Data) -> Data }`
  - `public enum AndroidKeys { public static func keycode(forHIDUsage: UInt32) -> Int32?; public static func button(_ name: String) -> Int32? }` and `public struct AndroidMetaState { public init(); public var value: Int32 { get }; public mutating func update(hidUsage: UInt32, down: Bool) }`

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
import AlasCore

struct ScrcpyTests {
    private static func bytes(_ values: [UInt8]) -> Data { Data(values) }

    /// A codec id, a session, a config packet, a key frame and a P frame, as the server sends them.
    private static let stream: Data = {
        var data = Data("h264".utf8)
        data += bytes([0x80, 0, 0, 0, 0, 0, 0x02, 0xD0, 0, 0, 0x06, 0x40]) // session 720×1600
        data += bytes([0x40, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3]) + bytes([1, 2, 3]) // config
        data += bytes([0x20, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 2]) + bytes([4, 5]) // key frame
        data += bytes([0x00, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 1]) + bytes([6]) // P frame
        return data
    }()

    private static let events: [ScrcpyVideoEvent] = [
        .session(width: 720, height: 1600), .config(bytes([1, 2, 3])),
        .frame(bytes([4, 5]), keyFrame: true), .frame(bytes([6]), keyFrame: false),
    ]

    @Test(arguments: [1, 5, 1000])
    func theVideoStreamParsesWhateverTheReadSizes(chunk: Int) throws {
        var parser = ScrcpyVideoParser()
        var events: [ScrcpyVideoEvent] = []
        var offset = 0
        while offset < Self.stream.count {
            let end = min(offset + chunk, Self.stream.count)
            events += try parser.feed(Self.stream.subdata(in: offset..<end))
            offset = end
        }
        #expect(events == Self.events)
    }

    @Test func anotherCodecIsRefused() {
        var parser = ScrcpyVideoParser()
        #expect(throws: ScrcpyError.unsupportedCodec(0x6832_3635)) { try parser.feed(Data("h265".utf8)) }
    }

    // The expected bytes are scrcpy v5.0.1's app/tests/test_control_msg_serialize.c.
    @Test func controlMessagesMatchScrcpysOwnEncoding() {
        #expect(ScrcpyControl.keycode(.up, keycode: 66, repeat: 5, metastate: 0x41) == Self.bytes([
            0x00, 0x01, 0x00, 0x00, 0x00, 0x42, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x41,
        ]))
        #expect(ScrcpyControl.touch(
            .down, x: 100, y: 200, width: 1080, height: 1920, pointerID: 0x1234_5678_8765_4321,
            pressure: 1, actionButton: 1, buttons: 1
        ) == Self.bytes([
            0x02, 0x00, 0x12, 0x34, 0x56, 0x78, 0x87, 0x65, 0x43, 0x21,
            0x00, 0x00, 0x00, 0x64, 0x00, 0x00, 0x00, 0xC8, 0x04, 0x38, 0x07, 0x80,
            0xFF, 0xFF, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        ]))
        #expect(ScrcpyControl.scroll(x: 260, y: 1026, width: 1080, height: 1920, horizontal: 16, vertical: -16, buttons: 1)
            == Self.bytes([
                0x03, 0x00, 0x00, 0x01, 0x04, 0x00, 0x00, 0x04, 0x02, 0x04, 0x38, 0x07, 0x80,
                0x7F, 0xFF, 0x80, 0x00, 0x00, 0x00, 0x00, 0x01,
            ]))
        #expect(ScrcpyControl.backOrScreenOn(.up) == Self.bytes([0x04, 0x01]))
        #expect(ScrcpyControl.getClipboard(copy: true) == Self.bytes([0x08, 0x01]))
        #expect(ScrcpyControl.setClipboard(sequence: 0x0102_0304_0506_0708, text: "hello, world!", paste: true)
            == Self.bytes([0x09, 1, 2, 3, 4, 5, 6, 7, 8, 1, 0, 0, 0, 0x0D]) + Data("hello, world!".utf8))
    }

    // scrcpy v5.0.1's app/tests/test_device_msg_deserialize.c, fed in two pieces.
    @Test func deviceMessagesParseAcrossReads() throws {
        var parser = ScrcpyDeviceMessageParser()
        let data = Self.bytes([0x00, 0, 0, 0, 3, 0x41, 0x42, 0x43, 0x01, 1, 2, 3, 4, 5, 6, 7, 8])
        var messages = try parser.feed(data.prefix(6))
        messages += try parser.feed(data.dropFirst(6))
        #expect(messages == [.clipboard("ABC"), .ackClipboard(0x0102_0304_0506_0708)])
    }

    @Test func annexBSplitsOnThreeAndFourByteStartCodes() {
        let data = Self.bytes([0, 0, 0, 1, 0x67, 0xAA, 0, 0, 1, 0x68, 0xBB, 0, 0, 0, 1, 0x65, 0xCC, 0xDD])
        #expect(H264AnnexB.nalUnits(data) == [Self.bytes([0x67, 0xAA]), Self.bytes([0x68, 0xBB]), Self.bytes([0x65, 0xCC, 0xDD])])
        #expect(H264AnnexB.parameterSets(data)?.sps == Self.bytes([0x67, 0xAA]))
        #expect(H264AnnexB.parameterSets(data)?.pps == Self.bytes([0x68, 0xBB]))
        #expect(H264AnnexB.avcc(Self.bytes([0, 0, 0, 1, 0x65, 0xCC, 0xDD])) == Self.bytes([0, 0, 0, 3, 0x65, 0xCC, 0xDD]))
    }

    @Test(arguments: [
        (UInt32(0x04), Int32(29)), (0x1D, 54), (0x1E, 8), (0x27, 7), (0x28, 66), (0x2A, 67), (0x2C, 62),
        (0x4F, 22), (0x52, 19), (0xE1, 59), (0x3A, 131),
    ] as [(UInt32, Int32)])
    func hidUsagesMapToAndroidKeycodes(usage: UInt32, keycode: Int32) {
        #expect(AndroidKeys.keycode(forHIDUsage: usage) == keycode)
    }

    @Test func heldModifiersSetTheMetaState() {
        var meta = AndroidMetaState()
        meta.update(hidUsage: 0xE1, down: true) // left shift
        #expect(meta.value == 0x41)
        meta.update(hidUsage: 0xE0, down: true) // left control
        #expect(meta.value == 0x3041)
        meta.update(hidUsage: 0xE1, down: false)
        #expect(meta.value == 0x3000)
    }
}
```

- [ ] **Step 2: Run them to see them fail**

`swift test --package-path Packages/AlasCore --filter ScrcpyTests` → build errors.

- [ ] **Step 3: Implement `Scrcpy.swift`**

```swift
import Foundation

public enum ScrcpyError: Error, Equatable, Sendable {
    case unsupportedCodec(UInt32)
    case unknownDeviceMessage(UInt8)
}

public enum ScrcpyVideoEvent: Equatable, Sendable {
    /// A new capture session: the video's size changed (a rotation).
    case session(width: Int, height: Int)
    /// The codec configuration: H.264's SPS and PPS, Annex B.
    case config(Data)
    case frame(Data, keyFrame: Bool)
}

/// scrcpy's video socket after the dummy byte and device name: a codec id,
/// then 12-byte session or frame headers, each frame followed by its payload.
public struct ScrcpyVideoParser: Sendable {
    private var buffer = Data()
    private var codecRead = false

    public init() {}

    public mutating func feed(_ data: Data) throws -> [ScrcpyVideoEvent] {
        buffer += data
        var events: [ScrcpyVideoEvent] = []
        if !codecRead {
            guard buffer.count >= 4 else { return [] }
            let codec = Self.u32(buffer, 0)
            guard codec == 0x6832_3634 else { throw ScrcpyError.unsupportedCodec(codec) } // "h264"
            buffer.removeFirst(4)
            codecRead = true
        }
        while buffer.count >= 12 {
            let first = buffer[buffer.startIndex]
            if first & 0x80 != 0 {
                events.append(.session(width: Int(Self.u32(buffer, 4)), height: Int(Self.u32(buffer, 8))))
                buffer.removeFirst(12)
                continue
            }
            let size = Int(Self.u32(buffer, 8))
            guard buffer.count >= 12 + size else { break }
            let flags = Self.u64(buffer, 0)
            let payload = buffer.subdata(in: buffer.startIndex + 12..<buffer.startIndex + 12 + size)
            buffer.removeFirst(12 + size)
            if flags & (1 << 62) != 0 {
                events.append(.config(payload))
            } else {
                events.append(.frame(payload, keyFrame: flags & (1 << 61) != 0))
            }
        }
        return events
    }

    static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        data.dropFirst(offset).prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    static func u64(_ data: Data, _ offset: Int) -> UInt64 {
        data.dropFirst(offset).prefix(8).reduce(0) { $0 << 8 | UInt64($1) }
    }
}

/// Messages to scrcpy's control socket.
public enum ScrcpyControl {
    public enum KeyAction: UInt8, Sendable { case down = 0, up = 1 }
    public enum TouchAction: UInt8, Sendable { case down = 0, up = 1, move = 2 }

    /// scrcpy's pointer id for a finger that isn't the mouse: touches act like the touchscreen.
    public static let fingerPointerID: UInt64 = .max - 1

    public static func keycode(_ action: KeyAction, keycode: Int32, repeat count: Int32 = 0, metastate: Int32 = 0) -> Data {
        var data = Data([0, action.rawValue])
        data.append(be: UInt32(bitPattern: keycode))
        data.append(be: UInt32(bitPattern: count))
        data.append(be: UInt32(bitPattern: metastate))
        return data
    }

    /// `x` and `y` are in the video's pixels; `width` and `height` must be the
    /// current session's size, or the server drops the event.
    public static func touch(
        _ action: TouchAction, x: Int32, y: Int32, width: UInt16, height: UInt16,
        pointerID: UInt64 = fingerPointerID, pressure: Double, actionButton: UInt32 = 0, buttons: UInt32 = 0
    ) -> Data {
        var data = Data([2, action.rawValue])
        data.append(be: pointerID)
        appendPosition(&data, x: x, y: y, width: width, height: height)
        data.append(be: pressure >= 1 ? UInt16.max : UInt16(max(0, pressure) * 65536))
        data.append(be: actionButton)
        data.append(be: buttons)
        return data
    }

    /// `horizontal` and `vertical` are scroll steps, clamped to ±16.
    public static func scroll(
        x: Int32, y: Int32, width: UInt16, height: UInt16, horizontal: Double, vertical: Double, buttons: UInt32 = 0
    ) -> Data {
        var data = Data([3])
        appendPosition(&data, x: x, y: y, width: width, height: height)
        data.append(be: UInt16(bitPattern: fixedPoint(horizontal / 16)))
        data.append(be: UInt16(bitPattern: fixedPoint(vertical / 16)))
        data.append(be: buttons)
        return data
    }

    public static func backOrScreenOn(_ action: KeyAction) -> Data {
        Data([4, action.rawValue])
    }

    /// `copy` true asks the device to copy the selection first.
    public static func getClipboard(copy: Bool) -> Data {
        Data([8, copy ? 1 : 0])
    }

    public static func setClipboard(sequence: UInt64, text: String, paste: Bool) -> Data {
        let utf8 = Data(text.utf8)
        var data = Data([9])
        data.append(be: sequence)
        data.append(paste ? 1 : 0)
        data.append(be: UInt32(utf8.count))
        return data + utf8
    }

    private static func appendPosition(_ data: inout Data, x: Int32, y: Int32, width: UInt16, height: UInt16) {
        data.append(be: UInt32(bitPattern: x))
        data.append(be: UInt32(bitPattern: y))
        data.append(be: width)
        data.append(be: height)
    }

    /// scrcpy's float to i16 fixed point over [-1, 1].
    private static func fixedPoint(_ value: Double) -> Int16 {
        let clamped = min(max(value, -1), 1)
        return clamped >= 1 ? .max : Int16(clamped * 32768)
    }
}

public enum ScrcpyDeviceMessage: Equatable, Sendable {
    case clipboard(String)
    case ackClipboard(UInt64)
    case uhidOutput(id: UInt16, data: Data)
}

/// The control socket's messages from the device.
public struct ScrcpyDeviceMessageParser: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func feed(_ data: Data) throws -> [ScrcpyDeviceMessage] {
        buffer += data
        var messages: [ScrcpyDeviceMessage] = []
        while let type = buffer.first {
            switch type {
            case 0:
                guard buffer.count >= 5 else { return messages }
                let length = Int(ScrcpyVideoParser.u32(buffer, 1))
                guard buffer.count >= 5 + length else { return messages }
                let text = buffer.subdata(in: buffer.startIndex + 5..<buffer.startIndex + 5 + length)
                messages.append(.clipboard(String(decoding: text, as: UTF8.self)))
                buffer.removeFirst(5 + length)
            case 1:
                guard buffer.count >= 9 else { return messages }
                messages.append(.ackClipboard(ScrcpyVideoParser.u64(buffer, 1)))
                buffer.removeFirst(9)
            case 2:
                guard buffer.count >= 5 else { return messages }
                let id = UInt16(ScrcpyVideoParser.u32(buffer, 1) >> 16)
                let size = Int(ScrcpyVideoParser.u32(buffer, 1) & 0xFFFF)
                guard buffer.count >= 5 + size else { return messages }
                messages.append(.uhidOutput(id: id, data: buffer.subdata(in: buffer.startIndex + 5..<buffer.startIndex + 5 + size)))
                buffer.removeFirst(5 + size)
            default:
                throw ScrcpyError.unknownDeviceMessage(type)
            }
        }
        return messages
    }
}

extension Data {
    mutating func append<T: FixedWidthInteger>(be value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
```

- [ ] **Step 4: Implement `H264AnnexB.swift`**

```swift
import Foundation

/// H.264 byte streams as Android's encoder writes them: NAL units after
/// 3- or 4-byte start codes.
public enum H264AnnexB {
    public static func nalUnits(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var units: [Data] = []
        var start: Int?
        var index = 0
        while index + 3 <= bytes.count {
            let three = bytes[index] == 0 && bytes[index + 1] == 0 && bytes[index + 2] == 1
            let four = index + 4 <= bytes.count && bytes[index] == 0 && bytes[index + 1] == 0
                && bytes[index + 2] == 0 && bytes[index + 3] == 1
            if three || four {
                if let start { units.append(Data(bytes[start..<index])) }
                index += four ? 4 : 3
                start = index
            } else {
                index += 1
            }
        }
        if let start, start < bytes.count { units.append(Data(bytes[start...])) }
        return units
    }

    /// The first SPS (type 7) and PPS (type 8) in a config packet.
    public static func parameterSets(_ config: Data) -> (sps: Data, pps: Data)? {
        let units = nalUnits(config)
        guard let sps = units.first(where: { $0.first.map { $0 & 0x1F == 7 } ?? false }),
              let pps = units.first(where: { $0.first.map { $0 & 0x1F == 8 } ?? false }) else { return nil }
        return (sps, pps)
    }

    /// The same NAL units, each after its 4-byte big-endian length, as VideoToolbox takes them.
    public static func avcc(_ data: Data) -> Data {
        var out = Data()
        for unit in nalUnits(data) {
            out.append(be: UInt32(unit.count))
            out += unit
        }
        return out
    }
}
```

- [ ] **Step 5: Implement `AndroidKeys.swift`**

```swift
/// Mac keys, as the USB HID usages the screen view sends, to Android keycodes.
public enum AndroidKeys {
    public static func keycode(forHIDUsage usage: UInt32) -> Int32? {
        switch usage {
        case 0x04...0x1D: Int32(29 + usage - 0x04) // A–Z
        case 0x1E...0x26: Int32(8 + usage - 0x1E) // 1–9
        case 0x27: 7 // 0
        case 0x3A...0x45: Int32(131 + usage - 0x3A) // F1–F12
        default: table[usage]
        }
    }

    private static let table: [UInt32: Int32] = [
        0x28: 66, 0x29: 111, 0x2A: 67, 0x2B: 61, 0x2C: 62, 0x2D: 69, 0x2E: 70, 0x2F: 71, 0x30: 72, 0x31: 73,
        0x33: 74, 0x34: 75, 0x35: 68, 0x36: 55, 0x37: 56, 0x38: 76, 0x39: 115,
        0x4A: 122, 0x4B: 92, 0x4C: 112, 0x4D: 123, 0x4E: 93, 0x4F: 22, 0x50: 21, 0x51: 20, 0x52: 19,
        0xE0: 113, 0xE1: 59, 0xE2: 57, 0xE3: 117, 0xE4: 114, 0xE5: 60, 0xE6: 58, 0xE7: 118,
    ]

    /// The gutter's buttons.
    public static func button(_ name: String) -> Int32? {
        switch name {
        case "back": 4
        case "home": 3
        case "app_switch": 187
        case "power": 26
        case "volume_up": 24
        case "volume_down": 25
        default: nil
        }
    }
}

/// Android's meta state for the modifiers held down.
public struct AndroidMetaState: Sendable {
    private var held: Set<UInt32> = []

    public init() {}

    /// Each modifier's `*_ON` bit and its side's bit.
    private static let bits: [UInt32: Int32] = [
        0xE0: 0x3000, // left control: CTRL_ON | CTRL_LEFT_ON
        0xE1: 0x41, // left shift: SHIFT_ON | SHIFT_LEFT_ON
        0xE2: 0x12, // left option: ALT_ON | ALT_LEFT_ON
        0xE3: 0x30000, // left command: META_ON | META_LEFT_ON
        0xE4: 0x5000, // right control
        0xE5: 0x81, // right shift
        0xE6: 0x22, // right option
        0xE7: 0x50000, // right command
    ]

    public var value: Int32 {
        held.reduce(0) { $0 | (Self.bits[$1] ?? 0) }
    }

    public mutating func update(hidUsage: UInt32, down: Bool) {
        guard Self.bits[hidUsage] != nil else { return }
        if down { held.insert(hidUsage) } else { held.remove(hidUsage) }
    }
}
```

- [ ] **Step 6: Run the tests**

`swift test --package-path Packages/AlasCore --filter ScrcpyTests` → all pass.

- [ ] **Step 7: Commit**

```bash
git add Packages/AlasCore/Sources/AlasFeatures/Devices/Android Packages/AlasCore/Tests/AlasCoreTests/ScrcpyTests.swift
git commit -m "feat(android): speak scrcpy's video and control protocol"
```

---

### Task 3: Fetch and bundle `scrcpy-server`

**Files:**
- Create: `scripts/fetch-scrcpy-server.sh`
- Modify: `scripts/embed-ghostty-resources.sh`
- Modify: `project.yml` (pre-build script), then `xcodegen`

**Interfaces:**
- Produces: `Contents/Resources/scrcpy/scrcpy-server` and `Contents/Resources/scrcpy/LICENSE` in the app.

- [ ] **Step 1: Write the fetch script**

```bash
#!/usr/bin/env bash
# Fetches the pinned scrcpy-server (Genymobile/scrcpy), the jar Alas pushes to
# an Android device to stream its screen, and scrcpy's Apache-2.0 licence into
# .build/scrcpy/, checking both against pinned SHA-256s.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"

version="5.0.1"
server_sha256="764eb6f79811d5211fe9df341120882ba9994c7a61b897d7bf3fb662e53bc536"
license_sha256="01c12035bf35af37241298dc7ad538eb2a07e5c940437bc6876feeaa9d1951d0"
server_url="https://github.com/Genymobile/scrcpy/releases/download/v${version}/scrcpy-server-v${version}"
license_url="https://raw.githubusercontent.com/Genymobile/scrcpy/v${version}/LICENSE"

srcroot="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
out_dir="${srcroot}/.build/scrcpy"

die() {
    echo "fetch-scrcpy-server.sh: error: $*" >&2
    exit 1
}

sha() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }

if [ "$(sha "${out_dir}/scrcpy-server")" = "${server_sha256}" ] && [ "$(sha "${out_dir}/LICENSE")" = "${license_sha256}" ]; then
    exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
curl -fsSL --retry 3 -o "${tmp}/scrcpy-server" "${server_url}" || die "couldn't download ${server_url}"
curl -fsSL --retry 3 -o "${tmp}/LICENSE" "${license_url}" || die "couldn't download ${license_url}"
[ "$(sha "${tmp}/scrcpy-server")" = "${server_sha256}" ] || die "scrcpy-server doesn't match its pinned SHA-256"
[ "$(sha "${tmp}/LICENSE")" = "${license_sha256}" ] || die "scrcpy's LICENSE doesn't match its pinned SHA-256"
mkdir -p "${out_dir}"
mv "${tmp}/scrcpy-server" "${tmp}/LICENSE" "${out_dir}/"
```

`chmod +x scripts/fetch-scrcpy-server.sh`.

- [ ] **Step 2: Embed it**

At the end of `scripts/embed-ghostty-resources.sh`:

```bash
# scrcpy-server, pushed to Android devices to stream their screens, and its licence.
scrcpy_source="${SRCROOT}/.build/scrcpy"
scrcpy_destination="${destination_root}/scrcpy"
if [ ! -f "${scrcpy_source}/scrcpy-server" ] || [ ! -f "${scrcpy_source}/LICENSE" ]; then
    echo "embed-ghostty-resources.sh: error: scrcpy-server not found in ${scrcpy_source}" >&2
    exit 1
fi
rm -rf "${scrcpy_destination}"
mkdir -p "${scrcpy_destination}"
rsync -a "${scrcpy_source}/scrcpy-server" "${scrcpy_source}/LICENSE" "${scrcpy_destination}/"
```

It is a jar for the device, not Mac code: `sign-and-notarize.sh` doesn't sign it (`codesign --deep` treats it as data).

- [ ] **Step 3: Pre-build script**

In `project.yml`, under the `Alas` target's `preBuildScripts`, after "Build Simulator Accessibility Helper":

```yaml
      - name: Fetch scrcpy Server
        script: '"${SRCROOT}/scripts/fetch-scrcpy-server.sh"'
        basedOnDependencyAnalysis: false
```

Run `xcodegen`; keep only the hunks for this script in the pbxproj (Global Constraints).

- [ ] **Step 4: Build and check the bundle**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -quiet build
APP=~/Library/Developer/Xcode/DerivedData/Alas-*/Build/Products/Debug/Alas.app
shasum -a 256 $APP/Contents/Resources/scrcpy/scrcpy-server
codesign --verify --deep --strict $APP && echo signed
```

Expected: the pinned SHA-256, and `signed`.

- [ ] **Step 5: Commit**

```bash
git add scripts/fetch-scrcpy-server.sh scripts/embed-ghostty-resources.sh project.yml Alas.xcodeproj/project.pbxproj
git commit -m "build(android): bundle scrcpy-server"
```

---

### Task 4: Android in the Devices tab's state (AlasCore)

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasFeatures/Devices/DevicesTabState.swift`
- Test: `Packages/AlasCore/Tests/AlasCoreTests/DevicesTabStateTests.swift`

**Interfaces:**
- Consumes: Task 1's `AndroidDevice`.
- Produces:
  - `DevicesTarget.android(String)`
  - `public struct AndroidListing: Equatable, Sendable { public let devices: [AndroidDevice]; public let avds: [String]; public let bootingAVDs: Set<String>; public let note: String?; public init(devices:avds:bootingAVDs:note:); public static func avdID(_ name: String) -> String }`
  - `public enum AndroidStage: Equatable, Sendable { case ready, booting, shutDown, unauthorized, offline }`
  - `public struct AndroidTarget: Equatable, Sendable { public let id: String; public let title: String; public let device: AndroidDevice?; public let avdName: String? }`
  - `DevicesTabState.Stage.android(AndroidTarget, AndroidStage)`, `DevicesTabState.androidRows: [Row]`, `DevicesTabState.androidNote: String?`
  - `resolve(…, android: AndroidListing? = nil)` (last parameter, defaulted, so existing callers compile).

- [ ] **Step 1: Write the failing tests**

Add to `DevicesTabStateTests`:

```swift
    static let emulator = AndroidDevice(
        serial: "emulator-5554", state: .ready, model: "sdk_gphone64_arm64", avdName: "Medium_Phone", release: "16"
    )
    static let phone = AndroidDevice(serial: "R5CT", state: .unauthorized, model: nil)

    private func resolve(
        simulators: [SimulatorDevice]? = [off], vms: [VMGuestOS: VMDeviceStatus] = [:],
        selection: DevicesTarget? = nil, android: AndroidListing?
    ) -> DevicesTabState {
        .resolve(
            simulators: simulators, listError: nil, vms: vms, selection: selection,
            bootingUDIDs: [], agentDriving: [], android: android
        )
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

    @Test func aSelectedAVDFollowsItsEmulatorOnceItRuns() {
        let state = resolve(
            selection: .android("avd:Medium_Phone"),
            android: AndroidListing(devices: [Self.emulator], avds: ["Medium_Phone"], bootingAVDs: [], note: nil)
        )
        #expect(state.selected == .android("emulator-5554"))
        #expect(state.stage == .android(
            AndroidTarget(id: "emulator-5554", title: "Medium Phone", device: Self.emulator, avdName: "Medium_Phone"), .ready
        ))
    }

    /// With no simulator booted, a ready Android device comes before a running VM.
    @Test func aReadyAndroidDeviceIsTheDefaultWhenNoSimulatorIsBooted() {
        let state = resolve(
            vms: [.macOS: .running], android: AndroidListing(devices: [Self.emulator], avds: [], bootingAVDs: [], note: nil)
        )
        #expect(state.selected == .android("emulator-5554"))
    }

    @Test func withoutTheSDKTheSectionShowsItsNote() {
        let note = "Install Android Studio or the SDK command-line tools to use Android devices"
        let state = resolve(android: AndroidListing(devices: [], avds: [], bootingAVDs: [], note: note))
        #expect(state.androidRows.isEmpty)
        #expect(state.androidNote == note)
    }
```

- [ ] **Step 2: Run them to see them fail**

`swift test --package-path Packages/AlasCore --filter DevicesTabStateTests` → build errors.

- [ ] **Step 3: Implement**

In `DevicesTabState.swift`:

1. `DevicesTarget`: add `/// An Android device by serial, or an AVD that isn't running as "avd:<name>".` `case android(String)`.
2. New types after `VMDeviceStatus`:

```swift
/// The Android devices the tab lists, or why there are none.
public struct AndroidListing: Equatable, Sendable {
    public let devices: [AndroidDevice]
    /// Every AVD, running or not.
    public let avds: [String]
    public let bootingAVDs: Set<String>
    /// Shown instead of rows: the SDK is missing, or adb failed.
    public let note: String?

    public init(devices: [AndroidDevice], avds: [String], bootingAVDs: Set<String>, note: String?) {
        self.devices = devices
        self.avds = avds
        self.bootingAVDs = bootingAVDs
        self.note = note
    }

    public static func avdID(_ name: String) -> String { "avd:" + name }
}

public enum AndroidStage: Equatable, Sendable {
    case ready, booting, shutDown, unauthorized, offline
}

public struct AndroidTarget: Equatable, Sendable {
    /// `DevicesTarget.android`'s value.
    public let id: String
    public let title: String
    /// The connected device; nil for an AVD that isn't running.
    public let device: AndroidDevice?
    public let avdName: String?

    public init(id: String, title: String, device: AndroidDevice?, avdName: String?) {
        self.id = id
        self.title = title
        self.device = device
        self.avdName = avdName
    }
}
```

3. `Stage`: add `case android(AndroidTarget, AndroidStage)`. `DevicesTabState`: add `public let androidRows: [Row]` and `/// Shown in the switcher's Android section instead of rows.` `public let androidNote: String?` (memberwise order: after `simulatorsNote`).
4. `resolve`: add the parameter `android: AndroidListing? = nil` last. Before `let chosen`:

```swift
        let androidEntries = Self.androidEntries(android)
        let androidRows = androidEntries.map { entry in
            Row(
                target: .android(entry.target.id), title: entry.target.title,
                detail: Self.detail(of: entry.stage, device: entry.target.device),
                tone: entry.stage == .ready ? .live : entry.stage == .booting ? .busy : .idle
            )
        }
```

Pass `androidEntries` to `choose(selection:simulators:vms:android:)`, add the stage case

```swift
        case .android(let id)?:
            androidEntries.first { $0.target.id == id }.map { .android($0.target, $0.stage) } ?? .loading
```

and return `androidRows: androidRows, androidNote: android?.note` in the initializer.

5. New helpers:

```swift
    /// Connected devices first (emulators still coming up are left out), then
    /// the AVDs that aren't running.
    private static func androidEntries(_ listing: AndroidListing?) -> [(target: AndroidTarget, stage: AndroidStage)] {
        guard let listing, listing.note == nil else { return [] }
        let devices = listing.devices.filter { !($0.isEmulator && $0.state == .offline) }
        var entries = devices.map { device -> (target: AndroidTarget, stage: AndroidStage) in
            let stage: AndroidStage = switch device.state {
            case .ready: device.avdName.map(listing.bootingAVDs.contains) == true ? .booting : .ready
            case .unauthorized: .unauthorized
            case .offline: .offline
            }
            return (AndroidTarget(id: device.serial, title: device.title, device: device, avdName: device.avdName), stage)
        }
        let running = Set(devices.compactMap(\.avdName))
        entries += listing.avds.filter { !running.contains($0) }.map { name in
            (
                AndroidTarget(
                    id: AndroidListing.avdID(name), title: name.replacingOccurrences(of: "_", with: " "),
                    device: nil, avdName: name
                ),
                listing.bootingAVDs.contains(name) ? .booting : .shutDown
            )
        }
        return entries
    }

    private static func detail(of stage: AndroidStage, device: AndroidDevice?) -> String {
        switch stage {
        case .ready: device?.release.map { "Android \($0)" } ?? "Android"
        case .booting: "Booting"
        case .shutDown: "Shut down"
        case .unauthorized: "Allow USB debugging"
        case .offline: "Offline"
        }
    }
```

6. `choose`: add the parameter `android: [(target: AndroidTarget, stage: AndroidStage)]` and, in the `switch selection`:

```swift
        case .android(let id)? where android.contains(where: { $0.target.id == id }):
            return selection
        case .android(let id)? where id.hasPrefix("avd:"):
            // The AVD booted: follow it to its emulator.
            let name = String(id.dropFirst(4))
            if let running = android.first(where: { $0.target.avdName == name && $0.target.device != nil }) {
                return .android(running.target.id)
            }
```

then after the booted-simulator line: `if let ready = android.first(where: { $0.stage == .ready }) { return .android(ready.target.id) }`, and after `if let first = simulators.first { … }`: `if let first = android.first { return .android(first.target.id) }`.

- [ ] **Step 4: Run the tests**

`swift test --package-path Packages/AlasCore --filter DevicesTabStateTests` → all pass, the existing ones unchanged.

- [ ] **Step 5: Commit**

```bash
git add Packages/AlasCore/Sources/AlasFeatures/Devices/DevicesTabState.swift Packages/AlasCore/Tests/AlasCoreTests/DevicesTabStateTests.swift
git commit -m "feat(android): list Android devices and AVDs in the Devices tab's state"
```

(The app doesn't build until Task 7 handles the new `Stage` case; Tasks 5–7 land together before anything is pushed. Run AlasCore's tests here.)

---

### Task 5: A screen source protocol, and the stage's frame and gutter as shared views

**Files:**
- Create: `Alas/Sources/Devices/DeviceScreenSource.swift`
- Create: `Alas/Sources/Devices/DeviceStageFrame.swift`
- Modify: `Alas/Sources/Devices/DeviceScreenView.swift`
- Modify: `Alas/Sources/Devices/DeviceStage.swift`
- Modify: `Alas/Sources/Devices/SimulatorStreamClient.swift` (`ResumeOnce` internal)

**Interfaces:**
- Produces:
  - `@MainActor protocol DeviceScreenSource: AnyObject { subscribe(udid:onFrame:onStop:) -> UUID; unsubscribe(udid:token:); touch(udid:phase:point:); key(udid:usage:down:); scroll(udid:point:dx:dy:) }` (scroll defaults to nothing), adopted by `SimulatorStreamClient`.
  - `DeviceScreenView(client: any DeviceScreenSource, …, canDrop: (URL) -> Bool = simulator apps)`.
  - `DeviceStageFrame(shape:landscape:dropTargeted:screen:gutter:)`, `DeviceGutter(enabled:content:)`, `DeviceGutterButton(icon:help:action:)`, `DeviceStagePill(content:)`, `DeviceAppInstallPill(install:onDismiss:)`.
  - `ResumeOnce` (internal, no longer `private`).

No new tests: a refactor of views; the simulator stage must look and behave the same.

- [ ] **Step 1: The protocol**

```swift
import AlasCore
import Foundation

/// What a device screen view streams frames from and sends input to: a
/// simulator through AlasSimService, or an Android device through scrcpy.
@MainActor
protocol DeviceScreenSource: AnyObject {
    func subscribe(
        udid: String,
        onFrame: @escaping @MainActor (DeviceFrame) -> Void,
        onStop: @escaping @MainActor (String) -> Void
    ) -> UUID
    func unsubscribe(udid: String, token: UUID)
    func touch(udid: String, phase: String, point: DeviceScreenPoint)
    func key(udid: String, usage: UInt32, down: Bool)
    /// A scroll over `point`, in wheel steps.
    func scroll(udid: String, point: DeviceScreenPoint, dx: Double, dy: Double)
}

extension DeviceScreenSource {
    /// Simulators take scrolls as drags; they ignore the wheel.
    func scroll(udid: String, point: DeviceScreenPoint, dx: Double, dy: Double) {}
}

extension SimulatorStreamClient: DeviceScreenSource {}
```

- [ ] **Step 2: The screen view takes any source**

In `DeviceScreenView.swift`:
- `let client: SimulatorStreamClient` → `let client: any DeviceScreenSource`.
- Add to the struct: `/// Whether a dropped file is one this device can run.` `var canDrop: (URL) -> Bool = { (try? SimulatorAppBundle.read($0)) != nil }`, passed through `makeNSView`/`updateNSView` like `onDropApp`.
- `DeviceScreenNSView`: `private weak var client: SimulatorStreamClient?` → `private weak var client: (any DeviceScreenSource)?`; `func attach(udid: String, client: any DeviceScreenSource)`; add `var canDrop: (URL) -> Bool = { _ in false }`; `droppedApp` returns `urls[0]` when `urls.count == 1 && canDrop(urls[0])`; rename the doc comment to "One file this device can run".
- Add, after `mouseUp`:

```swift
    override func scrollWheel(with event: NSEvent) {
        let point = location(event)
        guard allowsInput, let udid, let at = geometry.normalized(x: point.x, y: point.y) else {
            super.scrollWheel(with: event)
            return
        }
        // A trackpad's deltas are points; a wheel's are lines, one step each.
        let scale = event.hasPreciseScrollingDeltas ? 0.1 : 1
        client?.scroll(
            udid: udid, point: at, dx: Double(event.scrollingDeltaX) * scale, dy: Double(event.scrollingDeltaY) * scale
        )
    }
```

In `SimulatorStreamClient.swift`: `private final class ResumeOnce` → `final class ResumeOnce`.

- [ ] **Step 3: Extract the frame, gutter and pills**

`Alas/Sources/Devices/DeviceStageFrame.swift`: move `DeviceStage`'s `margin`, `gutter`, `bezel`, the `GeometryReader` layout of `body`, `fit`, `pill`, `appInstallPill` and the gutter capsule of `controls` into:

```swift
import AlasCore
import SwiftUI

/// A device's screen framed at its shape, turned for landscape, with a
/// gutter of hardware buttons on its right.
struct DeviceStageFrame<Screen: View, Gutter: View>: View {
    let shape: DeviceScreenShape?
    let landscape: Bool
    /// A drop the screen would take is over it: outline it.
    let dropTargeted: Bool
    @ViewBuilder let screen: () -> Screen
    @ViewBuilder let gutter: () -> Gutter
    @Environment(\.theme) private var theme

    private static let margin: CGFloat = 12
    private static let gutterWidth: CGFloat = 44
    private static let bezel: CGFloat = 4

    var body: some View {
        GeometryReader { geometry in
            let area = CGSize(
                width: max(0, geometry.size.width - Self.margin * 2 - Self.gutterWidth - Self.bezel * 2),
                height: max(0, geometry.size.height - Self.margin * 2 - Self.bezel * 2)
            )
            let size = Self.fit(shape, landscape: landscape, in: area)
            // The radius scales with the device's short side, which is its width in portrait.
            let radius = shape?.cornerRadius(forFittedWidth: landscape ? size.height : size.width) ?? 0
            HStack(spacing: 0) {
                screen()
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(theme.color("accent"), lineWidth: 2)
                            .opacity(dropTargeted ? 1 : 0)
                    )
                    .padding(Self.bezel)
                    .background(
                        RoundedRectangle(cornerRadius: radius + Self.bezel, style: .continuous)
                            .fill(Color(white: 0.067))
                            .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                gutter()
                    .frame(width: Self.gutterWidth)
            }
            .padding(Self.margin)
        }
    }

    /// The largest size of the screen's shape, turned for landscape, that
    /// fits `area`; all of it without a shape.
    static func fit(_ shape: DeviceScreenShape?, landscape: Bool, in area: CGSize) -> CGSize {
        guard let shape, shape.widthPoints > 0, shape.heightPoints > 0 else { return area }
        let (width, height) = landscape ? (shape.heightPoints, shape.widthPoints) : (shape.widthPoints, shape.heightPoints)
        let scale = min(area.width / width, area.height / height)
        return CGSize(width: width * scale, height: height * scale)
    }
}

/// The capsule of hardware buttons beside a device's screen.
struct DeviceGutter<Content: View>: View {
    let enabled: Bool
    @ViewBuilder let content: () -> Content
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        VStack(spacing: 2, content: content)
            .padding(scale.space[1])
            .background(theme.color("bg-2"), in: Capsule())
            .overlay(Capsule().strokeBorder(theme.color("line"), lineWidth: 0.5))
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.5)
            .frame(maxHeight: .infinity)
    }
}

struct DeviceGutterButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    var body: some View {
        ToolbarBtn(
            icon: icon, tooltip: help, metrics: ToolbarControlMetrics(width: 28, height: 28, cornerRadius: 14) // design-literal: pill-shaped hardware button, half its 28pt frame
        ) {
            action()
        }
    }
}
```

and the pills, moved unchanged from `DeviceStage` (`pill` → `DeviceStagePill`, `appInstallPill` → `DeviceAppInstallPill(install:onDismiss:)`, which uses `DeviceStagePill`).

`DeviceStage.body` becomes:

```swift
    var body: some View {
        let driver = control.driver(udid: device.udid, at: now)
        let allowsInput = VMDriver.allowsViewInput(driver)
        let landscape = (frameOrientation ?? client.lastFrame(udid: device.udid)?.orientation ?? .portrait).isLandscape
        DeviceStageFrame(shape: shape, landscape: landscape, dropTargeted: dropTargeted) {
            screen(allowsInput: allowsInput, driver: driver, landscape: landscape)
        } gutter: {
            controls(enabled: allowsInput)
        }
    }
```

`controls(enabled:)` becomes `DeviceGutter(enabled: enabled) { … }` with `DeviceGutterButton`s for the hardware buttons and the rotate buttons (their actions unchanged). The bottom overlay uses `DeviceAppInstallPill(install: appInstall, onDismiss: onDismissAppInstall)` and `DeviceStagePill { Text(notice)… }`; the driver pill keeps its own styling.

- [ ] **Step 4: Regenerate, build and run the device suites**

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation \
  -only-testing AlasTests/DeviceAgentControlTests -only-testing AlasTests/AccessibilityOverlayLayoutTests test
```

The app won't compile until Task 7 handles `Stage.android`: add a temporary `case .android: DevicesEmptyState(title: "Android")` arm in `DevicesTabView.stage` for this step, replaced in Task 7. Expected: suites pass.

- [ ] **Step 5: Commit**

Stage the new-file hunks of the pbxproj only, then:

```bash
git add Alas/Sources/Devices/DeviceScreenSource.swift Alas/Sources/Devices/DeviceStageFrame.swift Alas/Sources/Devices/DeviceScreenView.swift \
  Alas/Sources/Devices/DeviceStage.swift Alas/Sources/Devices/SimulatorStreamClient.swift Alas/Sources/Devices/DevicesTabView.swift \
  Alas.xcodeproj/project.pbxproj
git commit -m "refactor(devices): share the device screen view and stage frame beyond simulators"
```

---

### Task 6: The Android stream

**Files:**
- Create: `Alas/Sources/Devices/Android/AndroidSocket.swift`
- Create: `Alas/Sources/Devices/Android/H264Decoder.swift`
- Create: `Alas/Sources/Devices/Android/AndroidScreenSession.swift`
- Create: `Alas/Sources/Devices/Android/AndroidStreamClient.swift`
- Test: create `AlasTests/AndroidStreamConnectorTests.swift`

**Interfaces:**
- Consumes: Task 1's `AndroidControl`; Task 2's parsers and encoders; Task 5's `DeviceScreenSource`, `ResumeOnce`.
- Produces:
  - `enum AndroidStreamConnector { static func connect<Socket>(attempts: Int = 100, pause: () async throws -> Void = …, attempt: () async throws -> Socket?) async throws -> Socket }`, `enum AndroidStreamError: Error { case serverDidNotStart }`
  - `@MainActor @Observable final class AndroidStreamClient: DeviceScreenSource` with `init(control: @escaping @MainActor () -> AndroidControl?, serverJar: URL?)`, `videoSizes: [String: CGSize]`, `button(udid:name:)`, `paste(udid:text:)`, `copy(udid:) async -> String?`, `lastFrame(udid:) -> DeviceFrame?`.

- [ ] **Step 1: Write the failing connector test**

```swift
import Testing
@testable import Alas

struct AndroidStreamConnectorTests {
    struct Refused: Error {}

    @Test func itRetriesUntilTheServerAnswers() async throws {
        // adb refuses, then accepts and hangs up twice, then the server answers.
        var answers: [Result<Int?, Refused>] = [.failure(Refused()), .success(nil), .success(nil), .success(7)]
        let socket = try await AndroidStreamConnector.connect(pause: {}) { try answers.removeFirst().get() }
        #expect(socket == 7)
        #expect(answers.isEmpty)
    }

    @Test func itGivesUpWhenTheServerNeverAnswers() async {
        await #expect(throws: AndroidStreamError.serverDidNotStart) {
            try await AndroidStreamConnector.connect(attempts: 3, pause: {}) { nil as Int? }
        }
    }
}
```

Run `xcodegen` and `xcodebuild … -only-testing AlasTests/AndroidStreamConnectorTests test` → fails to build (`AndroidStreamConnector` missing).

- [ ] **Step 2: `AndroidSocket.swift`**

```swift
import Foundation
import Network

enum AndroidSocketError: Error, Equatable {
    case closed
    case failed(String)
}

/// A TCP connection to an `adb forward` port. Its callbacks run on one serial
/// queue, which the pumps reading it rely on.
final class AndroidSocket: @unchecked Sendable {
    private let connection: NWConnection
    static let queue = DispatchQueue(label: "io.nlopez.alas.android-socket")

    private init(_ connection: NWConnection) {
        self.connection = connection
    }

    static func open(port: UInt16) async throws -> AndroidSocket {
        guard let endpoint = NWEndpoint.Port(rawValue: port) else { throw AndroidSocketError.failed("No port.") }
        let connection = NWConnection(host: "127.0.0.1", port: endpoint, using: .tcp)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let once = ResumeOnce(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.resume(returning: ())
                case .failed(let error), .waiting(let error):
                    once.resume(throwing: AndroidSocketError.failed(error.localizedDescription))
                case .cancelled: once.resume(throwing: AndroidSocketError.closed)
                default: break
                }
            }
            connection.start(queue: queue)
        }
        return AndroidSocket(connection)
    }

    /// Opens a connection and reads the server's dummy byte; nil when adb
    /// accepted but nothing listens on the device yet.
    static func openAnswered(port: UInt16) async throws -> AndroidSocket? {
        let socket = try await open(port: port)
        do {
            _ = try await socket.read(exactly: 1)
            return socket
        } catch AndroidSocketError.closed {
            socket.close()
            return nil
        }
    }

    /// Whatever arrives next, up to 64 KB, on the socket's queue.
    func receive(_ handler: @escaping @Sendable (Result<Data, AndroidSocketError>) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                handler(.success(data))
            } else if let error {
                handler(.failure(.failed(error.localizedDescription)))
            } else {
                handler(.failure(.closed))
            }
            _ = isComplete
        }
    }

    func read(exactly count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let data, data.count == count {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: AndroidSocketError.failed(error.localizedDescription))
                } else {
                    continuation.resume(throwing: AndroidSocketError.closed)
                }
            }
        }
    }

    func write(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    func close() {
        connection.cancel()
    }
}

enum AndroidStreamError: Error, Equatable, LocalizedError {
    case serverDidNotStart

    var errorDescription: String? { "The Android screen server didn't start." }
}

enum AndroidStreamConnector {
    /// `adb forward` accepts a connection before the server listens, then
    /// hangs up; keep connecting until the server answers (10 s by default).
    static func connect<Socket>(
        attempts: Int = 100,
        pause: () async throws -> Void = { try await Task.sleep(for: .milliseconds(100)) },
        attempt: () async throws -> Socket?
    ) async throws -> Socket {
        for _ in 0..<attempts {
            if let socket = try? await attempt() { return socket }
            try await pause()
        }
        throw AndroidStreamError.serverDidNotStart
    }
}
```

Run the connector tests → pass.

- [ ] **Step 3: `H264Decoder.swift`**

```swift
import AlasCore
import CoreMedia
import Foundation
import VideoToolbox

/// Decodes scrcpy's H.264 into IOSurface-backed images the screen's layer
/// shows. Used from one queue at a time.
final class H264Decoder {
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    /// A config packet (SPS and PPS); a new one, after a rotation, replaces the session.
    func configure(_ config: Data) {
        guard let sets = H264AnnexB.parameterSets(config) else { return }
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
        var format: CMVideoFormatDescription?
        let status = sets.sps.withUnsafeBytes { sps in
            sets.pps.withUnsafeBytes { pps in
                let pointers = [
                    sps.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    pps.baseAddress!.assumingMemoryBound(to: UInt8.self),
                ]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: [sets.sps.count, sets.pps.count], nalUnitHeaderLength: 4,
                    formatDescriptionOut: &format
                )
            }
        }
        guard status == noErr, let format else { return }
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        ]
        var session: VTDecompressionSession?
        guard VTDecompressionSessionCreate(
            allocator: nil, formatDescription: format, decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary, outputCallback: nil, decompressionSessionOut: &session
        ) == noErr else { return }
        self.format = format
        self.session = session
    }

    /// The image for one frame's Annex B payload; nil before a config, or when it doesn't decode.
    func decode(_ frame: Data) -> CVPixelBuffer? {
        guard let format, let session else { return nil }
        let avcc = H264AnnexB.avcc(frame)
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: avcc.count, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &block
        ) == noErr, let block else { return nil }
        let copied = avcc.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = avcc.count
        guard CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0,
            sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample
        ) == noErr, let sample else { return nil }
        let output = DecodedImage()
        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            if status == noErr { output.image = image }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        return output.image
    }
}

/// The decoder's output handler is `@Sendable`; this carries its image out.
private final class DecodedImage: @unchecked Sendable {
    var image: CVPixelBuffer?
}
```

- [ ] **Step 4: `AndroidScreenSession.swift`**

```swift
import AlasCore
import CoreVideo
import Foundation
import IOSurface

/// One Android device's scrcpy server, its video and control sockets, and the
/// pumps reading them.
@MainActor
final class AndroidScreenSession {
    static let devicePath = "/data/local/tmp/alas-scrcpy-server.jar"

    let serial: String
    var onFrame: (DeviceFrame) -> Void = { _ in }
    var onSize: (CGSize) -> Void = { _ in }
    var onStop: (String) -> Void = { _ in }

    private let control: AndroidControl
    private let serverJar: URL
    private var server: Process?
    private var port: String?
    private var video: AndroidSocket?
    private var controlSocket: AndroidSocket?
    private let log = ServerLog()
    private var stopped = false
    private var clipboardWaiter: CheckedContinuation<String?, Never>?

    init(serial: String, control: AndroidControl, serverJar: URL) {
        self.serial = serial
        self.control = control
        self.serverJar = serverJar
    }

    func start() async {
        do {
            // A server left from a client that died still holds the device's encoder.
            _ = try? await control.adb(serial, ["shell", "pkill", "-f", "com.genymobile.scrcpy.Server"])
            // The server deletes itself when it exits, so it is pushed every time.
            _ = try await control.adb(serial, ["push", serverJar.path, Self.devicePath], timeout: 60)
            let scid = String(format: "%08x", UInt32.random(in: 1...0x7FFF_FFFF))
            let port = try await control.adb(serial, ["forward", "tcp:0", "localabstract:scrcpy_\(scid)"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let number = UInt16(port) else { throw AndroidControlError("adb didn't forward a port.") }
            self.port = port
            server = try launchServer(scid: scid)
            let video = try await AndroidStreamConnector.connect { try await AndroidSocket.openAnswered(port: number) }
            let controlSocket = try await AndroidSocket.open(port: number)
            guard !stopped else {
                video.close()
                controlSocket.close()
                return
            }
            self.video = video
            self.controlSocket = controlSocket
            _ = try await video.read(exactly: 64) // the device's name
            startPumps(video: video, control: controlSocket)
        } catch {
            fail("The screen couldn't start: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        tearDown()
    }

    func send(_ message: Data) {
        controlSocket?.write(message)
    }

    /// Asks the device to copy its selection and returns it; nil after 2 s.
    func copyClipboard() async -> String? {
        guard controlSocket != nil else { return nil }
        clipboardArrived(nil)
        return await withCheckedContinuation { continuation in
            clipboardWaiter = continuation
            send(ScrcpyControl.getClipboard(copy: true))
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.clipboardArrived(nil)
            }
        }
    }

    private func clipboardArrived(_ text: String?) {
        clipboardWaiter?.resume(returning: text)
        clipboardWaiter = nil
    }

    private func launchServer(scid: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: control.sdk.adb)
        process.arguments = [
            "-s", serial, "shell",
            "CLASSPATH=\(Self.devicePath) app_process / com.genymobile.scrcpy.Server 5.0.1 scid=\(scid) "
                + "tunnel_forward=true audio=false control=true max_size=1600 clipboard_autosync=false",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let log = self.log
        pipe.fileHandleForReading.readabilityHandler = { log.append($0.availableData) }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.fail("The screen stopped.") } }
        }
        try process.run()
        return process
    }

    private func startPumps(video: AndroidSocket, control: AndroidSocket) {
        AndroidVideoPump(
            socket: video,
            onSize: { [weak self] width, height in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.onSize(CGSize(width: width, height: height)) } }
            },
            onFrame: { [weak self] surface in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.onFrame(DeviceFrame(surface: surface, orientation: .portrait)) }
                }
            },
            onEnd: { [weak self] reason in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.fail(reason) } }
            }
        ).start()
        AndroidControlPump(socket: control) { [weak self] text in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.clipboardArrived(text) } }
        }.start()
    }

    private func fail(_ reason: String) {
        guard !stopped else { return }
        stopped = true
        tearDown()
        onStop(log.tail.map { "\(reason)\n\($0)" } ?? reason)
    }

    private func tearDown() {
        video?.close()
        controlSocket?.close()
        server?.terminationHandler = nil
        server?.terminate()
        clipboardArrived(nil)
        if let port {
            let control = self.control
            let serial = self.serial
            Task { _ = try? await control.adb(serial, ["forward", "--remove", "tcp:\(port)"]) }
        }
    }
}

/// The server's last output lines, for the stopped screen's detail.
final class ServerLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        lock.withLock {
            lines += text.split(whereSeparator: \.isNewline).map(String.init)
            lines = Array(lines.suffix(5))
        }
    }

    var tail: String? {
        lock.withLock { lines.isEmpty ? nil : lines.joined(separator: "\n") }
    }
}

/// Reads the video socket on the socket's queue and decodes as it goes.
final class AndroidVideoPump: @unchecked Sendable {
    private let socket: AndroidSocket
    private var parser = ScrcpyVideoParser()
    private let decoder = H264Decoder()
    private let onSize: @Sendable (Int, Int) -> Void
    private let onFrame: @Sendable (IOSurface) -> Void
    private let onEnd: @Sendable (String) -> Void

    init(
        socket: AndroidSocket, onSize: @escaping @Sendable (Int, Int) -> Void,
        onFrame: @escaping @Sendable (IOSurface) -> Void, onEnd: @escaping @Sendable (String) -> Void
    ) {
        self.socket = socket
        self.onSize = onSize
        self.onFrame = onFrame
        self.onEnd = onEnd
    }

    func start() {
        socket.receive { [self] result in
            switch result {
            case .failure:
                onEnd("The screen stopped.")
            case .success(let data):
                do {
                    for event in try parser.feed(data) { handle(event) }
                    start()
                } catch {
                    onEnd("The device sent video Alas can't read.")
                }
            }
        }
    }

    private func handle(_ event: ScrcpyVideoEvent) {
        switch event {
        case .session(let width, let height):
            onSize(width, height)
        case .config(let config):
            decoder.configure(config)
        case .frame(let payload, _):
            guard let image = decoder.decode(payload),
                  let surface = CVPixelBufferGetIOSurface(image)?.takeUnretainedValue() else { return }
            onFrame(surface)
        }
    }
}

/// Reads the control socket's device messages: the clipboard after ⌘C.
final class AndroidControlPump: @unchecked Sendable {
    private let socket: AndroidSocket
    private var parser = ScrcpyDeviceMessageParser()
    private let onClipboard: @Sendable (String) -> Void

    init(socket: AndroidSocket, onClipboard: @escaping @Sendable (String) -> Void) {
        self.socket = socket
        self.onClipboard = onClipboard
    }

    func start() {
        socket.receive { [self] result in
            guard case .success(let data) = result, let messages = try? parser.feed(data) else { return }
            for case .clipboard(let text) in messages { onClipboard(text) }
            start()
        }
    }
}
```

(If the compiler rejects `takeUnretainedValue()` as `IOSurfaceRef` where `IOSurface` is expected, add `as IOSurface`; they are the same toll-free bridged type, which `DeviceScreenView` already relies on with `surface as IOSurfaceRef`.)

- [ ] **Step 5: `AndroidStreamClient.swift`**

```swift
import AlasCore
import Foundation
import Observation

/// Alas's scrcpy client: one session per Android device someone is watching,
/// with its frames fanned out to the screens showing it.
@MainActor
@Observable
final class AndroidStreamClient: DeviceScreenSource {
    private struct Screen {
        let onFrame: @MainActor (DeviceFrame) -> Void
        let onStop: @MainActor (String) -> Void
    }

    /// Each streamed device's current video size, upright; it changes when the device rotates.
    private(set) var videoSizes: [String: CGSize] = [:]

    @ObservationIgnored private let control: @MainActor () -> AndroidControl?
    @ObservationIgnored private let serverJar: URL?
    @ObservationIgnored private var sessions: [String: AndroidScreenSession] = [:]
    @ObservationIgnored private var screens: [String: [UUID: Screen]] = [:]
    @ObservationIgnored private var subscriptions = StreamSubscriptions()
    @ObservationIgnored private var lastFrames: [String: DeviceFrame] = [:]
    @ObservationIgnored private var metaStates: [String: AndroidMetaState] = [:]
    @ObservationIgnored private var clipboardSequence: UInt64 = 0

    init(
        control: @escaping @MainActor () -> AndroidControl?,
        serverJar: URL? = Bundle.main.resourceURL?.appendingPathComponent("scrcpy/scrcpy-server")
    ) {
        self.control = control
        self.serverJar = serverJar
    }

    func subscribe(
        udid: String, onFrame: @escaping @MainActor (DeviceFrame) -> Void, onStop: @escaping @MainActor (String) -> Void
    ) -> UUID {
        let token = UUID()
        screens[udid, default: [:]][token] = Screen(onFrame: onFrame, onStop: onStop)
        if subscriptions.add(udid) == .start { start(udid) }
        return token
    }

    func unsubscribe(udid: String, token: UUID) {
        screens[udid]?[token] = nil
        if screens[udid]?.isEmpty == true { screens[udid] = nil }
        if subscriptions.remove(udid) == .stop {
            sessions.removeValue(forKey: udid)?.stop()
            lastFrames[udid] = nil
            videoSizes[udid] = nil
            metaStates[udid] = nil
        }
    }

    func touch(udid: String, phase: String, point: DeviceScreenPoint) {
        guard let session = sessions[udid], let size = videoSizes[udid] else { return }
        let action: ScrcpyControl.TouchAction = switch phase {
        case "begin": .down
        case "end": .up
        default: .move
        }
        session.send(ScrcpyControl.touch(
            action, x: Int32(point.x * size.width), y: Int32(point.y * size.height),
            width: UInt16(size.width), height: UInt16(size.height), pressure: action == .up ? 0 : 1
        ))
    }

    func key(udid: String, usage: UInt32, down: Bool) {
        guard let session = sessions[udid] else { return }
        metaStates[udid, default: AndroidMetaState()].update(hidUsage: usage, down: down)
        guard let keycode = AndroidKeys.keycode(forHIDUsage: usage) else { return }
        session.send(ScrcpyControl.keycode(down ? .down : .up, keycode: keycode, metastate: metaStates[udid]?.value ?? 0))
    }

    func scroll(udid: String, point: DeviceScreenPoint, dx: Double, dy: Double) {
        guard let session = sessions[udid], let size = videoSizes[udid] else { return }
        session.send(ScrcpyControl.scroll(
            x: Int32(point.x * size.width), y: Int32(point.y * size.height),
            width: UInt16(size.width), height: UInt16(size.height), horizontal: dx, vertical: dy
        ))
    }

    /// A gutter button: back, home, app_switch, power, volume_up, volume_down.
    func button(udid: String, name: String) {
        guard let session = sessions[udid], let keycode = AndroidKeys.button(name) else { return }
        session.send(ScrcpyControl.keycode(.down, keycode: keycode))
        session.send(ScrcpyControl.keycode(.up, keycode: keycode))
    }

    /// Puts `text` on the device's clipboard and pastes it into the focused field.
    func paste(udid: String, text: String) {
        clipboardSequence += 1
        sessions[udid]?.send(ScrcpyControl.setClipboard(sequence: clipboardSequence, text: text, paste: true))
    }

    /// Copies the device's selection; nil when nothing came back in 2 s.
    func copy(udid: String) async -> String? {
        await sessions[udid]?.copyClipboard()
    }

    func lastFrame(udid: String) -> DeviceFrame? {
        lastFrames[udid]
    }

    private func start(_ serial: String) {
        guard let control = control(), let serverJar, FileManager.default.fileExists(atPath: serverJar.path) else {
            return stopped(serial, reason: "The Android screen server is missing from Alas.")
        }
        let session = AndroidScreenSession(serial: serial, control: control, serverJar: serverJar)
        session.onFrame = { [weak self] frame in self?.deliver(serial, frame) }
        session.onSize = { [weak self] size in self?.videoSizes[serial] = size }
        session.onStop = { [weak self] reason in self?.stopped(serial, reason: reason) }
        sessions[serial] = session
        Task { await session.start() }
    }

    private func deliver(_ serial: String, _ frame: DeviceFrame) {
        lastFrames[serial] = frame
        for screen in screens[serial]?.values.map({ $0 }) ?? [] { screen.onFrame(frame) }
    }

    private func stopped(_ serial: String, reason: String) {
        sessions[serial] = nil
        for screen in screens[serial]?.values.map({ $0 }) ?? [] { screen.onStop(reason) }
    }
}
```

- [ ] **Step 6: Build and run the connector tests**

```bash
xcodegen
xcodebuild … -only-testing AlasTests/AndroidStreamConnectorTests test
```

(Keep Task 5's temporary `DevicesTabView` arm until Task 7.) Expected: 2 tests pass.

- [ ] **Step 7: Commit**

Stage the new-file hunks of the pbxproj only, then:

```bash
git add Alas/Sources/Devices/Android AlasTests/AndroidStreamConnectorTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(android): stream and drive an Android screen with scrcpy"
```

---

### Task 7: The Android pane model and the tab

**Files:**
- Create: `Alas/Sources/Devices/Android/AndroidPaneModel.swift`
- Create: `Alas/Sources/Devices/Android/AndroidDeviceStage.swift`
- Modify: `Packages/AlasCore/Sources/AlasFeatures/Devices/Android/AndroidControl.swift` (`devices(known:)`)
- Modify: `Alas/Sources/App/AppState.swift`, `Alas/Sources/Devices/AppState+DevicesTab.swift`
- Modify: `Alas/Sources/Devices/DevicesTabView.swift`, `Alas/Sources/Devices/DevicesSwitcher.swift`

**Interfaces:**
- Consumes: Tasks 1, 4, 5 and 6.
- Produces: `AppState.androidPane: AndroidPaneModel`, `AppState.androidStreams: AndroidStreamClient`; `AndroidPaneModel` with `control`, `listing`, `checkSDK()`, `refresh()`, `pollWhileVisible()`, `boot(avd:)`, `shutDown(_:)`, `rotate(_:left:)`, `installAndLaunch(_:on:)`, `appInstalls`, `notices`, `show(_:serial:)`, `dismissAppInstall(serial:)`, `errors`.

No new tests: state decisions are pinned in Task 4; this is wiring and views.

- [ ] **Step 1: Cache what doesn't change between polls**

In `AndroidControl.devices()`, take `known: [String: AndroidDevice] = [:]` and, for a ready device whose serial is in `known` with a `release`, copy `avdName` and `release` from it instead of asking `adb` again. (Each poll then costs one `adb devices -l` once devices are known.)

- [ ] **Step 2: `AndroidPaneModel.swift`**

```swift
import AlasCore
import AppKit
import Foundation
import Observation

/// The Android devices and AVDs on this Mac, shared by every worktree's
/// Devices tab.
@MainActor
@Observable
final class AndroidPaneModel {
    /// The user's SDK; nil until `checkSDK()`, and when there is none.
    private(set) var control: AndroidControl?
    private(set) var sdkChecked = false
    private(set) var devices: [AndroidDevice]?
    private(set) var avds: [String] = []
    private(set) var listError: String?
    private(set) var bootingAVDs: Set<String> = []
    /// The last boot or shutdown failure, by `DevicesTarget.android` value.
    private(set) var errors: [String: String] = [:]
    private(set) var appInstalls: [String: DevicePaneModel.AppInstall] = [:]
    private(set) var notices: [String: String] = [:]
    @ObservationIgnored private var noticeTasks: [String: Task<Void, Never>] = [:]

    static let noSDK = "Install Android Studio or the SDK command-line tools to use Android devices"

    func checkSDK() {
        guard !sdkChecked else { return }
        control = AndroidSDK.locate().map(AndroidControl.init)
        sdkChecked = true
    }

    /// What the Devices tab lists; nil while the first list loads.
    var listing: AndroidListing? {
        guard sdkChecked else { return nil }
        guard control != nil else { return AndroidListing(devices: [], avds: [], bootingAVDs: [], note: Self.noSDK) }
        if let listError { return AndroidListing(devices: [], avds: [], bootingAVDs: [], note: listError) }
        guard let devices else { return nil }
        return AndroidListing(devices: devices, avds: avds, bootingAVDs: bootingAVDs, note: nil)
    }

    func refresh() async {
        guard let control else { return }
        do {
            let known = Dictionary((devices ?? []).map { ($0.serial, $0) }, uniquingKeysWith: { first, _ in first })
            devices = try await control.devices(known: known)
            avds = (try? await control.avds()) ?? avds
            listError = nil
        } catch {
            listError = error.localizedDescription
        }
    }

    func pollWhileVisible() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(3))
        }
    }

    func boot(avd: String) async {
        guard let control else { return }
        let id = AndroidListing.avdID(avd)
        errors[id] = nil
        bootingAVDs.insert(avd)
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("alas-emulator-\(avd).log")
        do {
            let emulator = try control.launchEmulator(avd: avd, log: log)
            _ = try await control.waitForBoot(avd: avd, emulator: emulator, log: log)
        } catch {
            errors[id] = error.localizedDescription
        }
        await refresh()
        bootingAVDs.remove(avd)
    }

    func shutDown(_ device: AndroidDevice) async {
        errors[device.serial] = nil
        do {
            try await control?.kill(serial: device.serial)
        } catch {
            errors[device.serial] = error.localizedDescription
        }
        await refresh()
    }

    func rotate(_ device: AndroidDevice, left: Bool) async {
        guard let control else { return }
        do {
            let current = try await control.rotation(serial: device.serial)
            try await control.setRotation(serial: device.serial, AndroidRotation.turned(current, left: left))
        } catch {
            show("Couldn't rotate: \(error.localizedDescription)", serial: device.serial)
        }
    }

    func installAndLaunch(_ apk: URL, on device: AndroidDevice) async {
        guard let control else { return }
        let name = apk.deletingPathExtension().lastPathComponent
        appInstalls[device.serial] = .installing(name)
        do {
            try await control.install(serial: device.serial, apk: apk)
            guard let package = await control.packageName(apk: apk) else {
                appInstalls[device.serial] = nil
                return show("Installed; open it from the launcher.", serial: device.serial)
            }
            appInstalls[device.serial] = .launching(name)
            try await control.launch(serial: device.serial, package: package)
            appInstalls[device.serial] = nil
        } catch {
            appInstalls[device.serial] = .failed("Couldn't open \(name): \(error.localizedDescription)")
        }
    }

    func dismissAppInstall(serial: String) {
        appInstalls[serial] = nil
    }

    func show(_ notice: String, serial: String) {
        notices[serial] = notice
        noticeTasks[serial]?.cancel()
        noticeTasks[serial] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.notices[serial] = nil
        }
    }
}
```

- [ ] **Step 3: AppState**

Next to `devicePane` / `simulatorStreams`:

```swift
    let androidPane = AndroidPaneModel()
    /// Android screens, through scrcpy; the SDK comes from `androidPane`.
    @ObservationIgnored lazy var androidStreams = AndroidStreamClient { [weak self] in self?.androidPane.control }
```

In `devicesTabState(worktree:selection:)`, pass `android: androidPane.listing` to `resolve`.

- [ ] **Step 4: `AndroidDeviceStage.swift`**

```swift
import AlasCore
import AppKit
import SwiftUI

/// A connected Android device's live screen, framed at its video's shape,
/// with Back, Home, Recents, Power, volume and rotation in the gutter.
struct AndroidDeviceStage: View {
    let device: AndroidDevice
    let client: AndroidStreamClient
    let pane: AndroidPaneModel
    @Environment(\.theme) private var theme
    @State private var streamError: String?
    @State private var streamGeneration = 0
    @State private var dropTargeted = false

    var body: some View {
        DeviceStageFrame(shape: shape, landscape: false, dropTargeted: dropTargeted) {
            screen
        } gutter: {
            DeviceGutter(enabled: streamError == nil) {
                button("arrow.uturn.backward", "Back", "back")
                button("circle", "Home", "home")
                button("square.on.square", "Recents", "app_switch")
                button("power", "Power", "power")
                button("speaker.wave.3", "Volume up", "volume_up")
                button("speaker.wave.1", "Volume down", "volume_down")
                DeviceGutterButton(icon: "rotate.left", help: "Rotate left") { rotate(left: true) }
                DeviceGutterButton(icon: "rotate.right", help: "Rotate right") { rotate(left: false) }
            }
        }
    }

    /// The video's own shape, upright, with corners like a phone's.
    private var shape: DeviceScreenShape? {
        client.videoSizes[device.serial].map {
            DeviceScreenShape(widthPoints: $0.width, heightPoints: $0.height, cornerRadiusPoints: min($0.width, $0.height) * 0.06)
        }
    }

    private var screen: some View {
        ZStack {
            DeviceScreenView(
                udid: device.serial, client: client, onStopped: { streamError = $0 },
                onDropApp: { apk in Task { await pane.installAndLaunch(apk, on: device) } },
                onDropTargeted: { dropTargeted = $0 },
                onPaste: paste, onCopy: copy,
                canDrop: { $0.pathExtension.lowercased() == "apk" }
            )
            .id("\(device.serial):\(streamGeneration)")
            if let streamError {
                theme.color("bg-2").opacity(0.92)
                DevicesEmptyState(
                    symbol: "exclamationmark.triangle", title: "The screen stopped", detail: streamError,
                    action: .init(title: "Retry", icon: "arrow.clockwise") {
                        self.streamError = nil
                        streamGeneration += 1
                    }
                )
            }
        }
        .overlay(alignment: .bottom) {
            if let install = pane.appInstalls[device.serial] {
                DeviceAppInstallPill(install: install) { pane.dismissAppInstall(serial: device.serial) }
            } else if let notice = pane.notices[device.serial] {
                DeviceStagePill { Text(notice).foregroundStyle(theme.color("fg")) }
            }
        }
    }

    private func button(_ icon: String, _ help: String, _ name: String) -> some View {
        DeviceGutterButton(icon: icon, help: help) { client.button(udid: device.serial, name: name) }
    }

    private func rotate(left: Bool) {
        Task { await pane.rotate(device, left: left) }
    }

    private func paste() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            return pane.show("The clipboard has no text to paste.", serial: device.serial)
        }
        client.paste(udid: device.serial, text: text)
    }

    private func copy() {
        Task {
            guard let text = await client.copy(udid: device.serial) else {
                return pane.show("Nothing was copied. Select some text first.", serial: device.serial)
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            pane.show("Copied", serial: device.serial)
        }
    }
}
```

(Match `DeviceScreenView`'s parameter order: put `canDrop` where Task 5 declared it.)

- [ ] **Step 5: The tab and the switcher**

`DevicesTabView`:
- A second `.task` after the simulators' one:

```swift
        .task {
            state.androidPane.checkSDK()
            guard state.androidPane.control != nil else { return }
            await state.androidPane.pollWhileVisible()
        }
```

- Replace Task 5's temporary arm with:

```swift
        case .android(let target, .ready):
            if let device = target.device {
                AndroidDeviceStage(device: device, client: state.androidStreams, pane: state.androidPane)
                    .id(device.serial)
            }
        case .android(let target, .booting):
            DevicesEmptyState(title: "Booting \(target.title)…", detail: "A cold boot takes about 20 seconds.")
        case .android(let target, .shutDown):
            let error = state.androidPane.errors[target.id]
            DevicesEmptyState(
                symbol: "candybarphone", title: "\(target.title) is shut down",
                detail: error ?? "Android emulator", detailTone: error == nil ? "fg-dim" : "warn",
                action: .init(title: "Boot", icon: "power") {
                    rps.devicesSelection = .android(target.id)
                    if let avd = target.avdName { Task { await state.androidPane.boot(avd: avd) } }
                }
            )
        case .android(let target, .unauthorized):
            DevicesEmptyState(
                symbol: "lock", title: "Allow USB debugging on the phone",
                detail: "Unlock \(target.title) and allow this Mac when it asks.",
                action: .init(title: "Retry", icon: "arrow.clockwise") { Task { await state.androidPane.refresh() } }
            )
        case .android(let target, .offline):
            DevicesEmptyState(
                symbol: "candybarphone", title: "\(target.title) is offline",
                detail: "Reconnect it, or restart adb with `adb kill-server`.",
                action: .init(title: "Retry", icon: "arrow.clockwise") { Task { await state.androidPane.refresh() } }
            )
```

`DevicesSwitcher.body`'s menu, between the Simulators section and the VMs section:

```swift
            if !state.androidRows.isEmpty || state.androidNote != nil {
                Section("Android") {
                    if let note = state.androidNote {
                        Text(note)
                    }
                    ForEach(state.androidRows) { item($0) }
                }
            }
```

- [ ] **Step 6: Build**

`xcodegen`, then `xcodebuild … -quiet build`. Fix any remaining exhaustive switch over `DevicesTabState.Stage` or `DevicesTarget` the compiler reports (`RightPaneView.devicesActions` and `DesignCaptureDevices` use `if case`, so they compile; Task 8 adds Android's toolbar).

- [ ] **Step 7: Commit**

Stage the new-file hunks of the pbxproj only, then:

```bash
git add Alas/Sources/Devices/Android Packages/AlasCore/Sources/AlasFeatures/Devices/Android/AndroidControl.swift \
  Alas/Sources/App/AppState.swift Alas/Sources/Devices/AppState+DevicesTab.swift Alas/Sources/Devices/DevicesTabView.swift \
  Alas/Sources/Devices/DevicesSwitcher.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(android): show Android devices in the Devices tab"
```

---

### Task 8: Toolbar: screenshot, recording and Shut Down

**Files:**
- Create: `Alas/Sources/Devices/Android/AndroidActions.swift`
- Create: `Alas/Sources/Devices/Android/AndroidScreenRecording.swift`
- Modify: `Alas/Sources/Devices/DeviceScreenshot.swift`
- Modify: `Alas/Sources/App/AppState.swift` (`deviceRecorder` factory and Desktop naming)
- Modify: `Alas/Sources/Right/RightPaneView.swift`

**Interfaces:**
- Consumes: Task 7's `AndroidPaneModel`; `DeviceRecorder`, `ScreenRecording`.
- Produces: `DeviceScreenshot.savePNGToDesktop(_:kind:deviceName:now:)`, `DeviceScreenshot.moveRecordingToDesktop(_:deviceName:kind:now:)`.

- [ ] **Step 1: Desktop naming**

In `DeviceScreenshot`:

```swift
    /// A PNG the device made itself, such as `adb exec-out screencap -p`'s.
    static func savePNGToDesktop(_ png: Data, kind: String, deviceName: String, now: Date = .now) throws -> URL {
        let file = try desktopFile(kind, deviceName: deviceName, extension: "png", now: now)
        try png.write(to: file, options: .withoutOverwriting)
        return file
    }
```

and give `moveRecordingToDesktop` a `kind: String = "Simulator Recording"` parameter (after `deviceName`), with the extension taken from `recording.pathExtension` instead of `"mov"`.

- [ ] **Step 2: `AndroidScreenRecording.swift`**

```swift
import AlasCore
import Foundation

/// One running `adb shell screenrecord`, which stops by itself after 3 minutes.
@MainActor
final class AndroidScreenRecording: ScreenRecording {
    var onExit: ((Bool) -> Void)?

    private let control: AndroidControl
    private let serial: String
    private let file: URL
    private let remote = "/sdcard/alas-recording-\(UUID().uuidString.prefix(8)).mp4"
    private let process = Process()
    private var stopping = false

    init(control: AndroidControl, serial: String, file: URL) throws {
        self.control = control
        self.serial = serial
        self.file = file
        process.executableURL = URL(fileURLWithPath: control.sdk.adb)
        process.arguments = ["-s", serial, "shell", "screenrecord", "--time-limit", "180", remote]
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.endedByItself() } }
        }
        try process.run()
    }

    func stop() async -> Bool {
        stopping = true
        // SIGINT lets screenrecord finish the file.
        _ = try? await control.adb(serial, ["shell", "pkill", "-INT", "screenrecord"])
        let deadline = ContinuousClock.now + .seconds(5)
        while process.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return await pull()
    }

    private func endedByItself() {
        guard !stopping else { return }
        Task { onExit?(await pull()) }
    }

    /// Copies the video to `file` and deletes it from the device.
    private func pull() async -> Bool {
        let pulled = (try? await control.adb(serial, ["pull", remote, file.path], timeout: 120)) != nil
        _ = try? await control.adb(serial, ["shell", "rm", "-f", remote])
        return pulled && FileManager.default.fileExists(atPath: file.path)
    }
}
```

- [ ] **Step 3: The recorder makes Android recordings, and names them**

In `AppState.deviceRecorder`:

```swift
        let recorder = DeviceRecorder { [weak self] udid, file in
            if let control = self?.androidPane.control, self?.androidPane.devices?.contains(where: { $0.serial == udid }) == true {
                return try AndroidScreenRecording(control: control, serial: udid, file: file)
            }
            return try LiveScreenRecording(udid: udid, file: file)
        }
```

and in `onUserRecordingEnded`, name Android ones by their title:

```swift
            let android = self?.androidPane.devices?.first { $0.serial == udid }
            let name = android?.title ?? self?.devicePane.devices?.first { $0.udid == udid }?.name ?? "Simulator"
            do {
                return try DeviceScreenshot.moveRecordingToDesktop(
                    finished.file, deviceName: name, kind: android == nil ? "Simulator Recording" : "Android Recording"
                )
            } catch { … unchanged … }
```

- [ ] **Step 4: `AndroidActions.swift`**

```swift
import AlasCore
import SwiftUI

/// The Devices tab's toolbar actions for an Android device: a screen
/// recording, a screenshot to the Desktop, and Shut Down for an emulator.
struct AndroidActions: View {
    let device: AndroidDevice
    let pane: AndroidPaneModel
    let recorder: DeviceRecorder
    let onShutDown: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale
    @State private var notice: String?

    var body: some View {
        HStack(spacing: 2) {
            if let notice {
                Text(notice)
                    .font(scale.caption.font(weight: .regular))
                    .foregroundStyle(theme.color("fg-dim"))
                    .lineLimit(1)
                    .transition(.opacity)
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(2))
                        withAnimation { self.notice = nil }
                    }
            }
            recordButton
            ToolbarBtn(icon: "camera", tooltip: "Save screenshot to Desktop") { Task { await saveScreenshot() } }
            if device.isEmulator {
                ToolbarMenuButton(iconName: "ellipsis", help: "More") {
                    Button("Shut Down", action: onShutDown)
                }
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private var recordButton: some View {
        switch recorder.owner(udid: device.serial) {
        case nil:
            ToolbarBtn(icon: "record.circle", tooltip: "Record screen (up to 3 minutes)") {
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("alas-recording-\(UUID().uuidString).mp4")
                do throws(DeviceRecorder.Failure) {
                    try recorder.start(udid: device.serial, owner: .user, file: file)
                } catch {
                    withAnimation { notice = "Couldn't start recording" }
                }
            }
        case .user:
            ToolbarBtn(icon: "stop.circle.fill", tooltip: "Stop recording", isActive: true) {
                Task { await stopRecording() }
            }
        case .agent:
            ToolbarBtn(icon: "record.circle", tooltip: "An agent is recording", isActive: true) {}
                .disabled(true)
        }
    }

    private func stopRecording() async {
        let text: String
        do {
            _ = try await recorder.stop(udid: device.serial, owner: .user)
            text = "Saved to Desktop"
        } catch DeviceRecorder.Failure.notSaved {
            text = "Couldn't save to the Desktop; it's shown in Finder"
        } catch {
            text = "Couldn't save the recording"
        }
        withAnimation { notice = text }
    }

    private func saveScreenshot() async {
        let text: String
        do {
            guard let control = pane.control else { throw AndroidControlError("No Android SDK.") }
            let png = try await control.screenshot(serial: device.serial)
            _ = try DeviceScreenshot.savePNGToDesktop(png, kind: "Android Screenshot", deviceName: device.title)
            text = "Saved to Desktop"
        } catch {
            text = "Couldn't save the screenshot"
        }
        withAnimation { notice = text }
    }
}
```

- [ ] **Step 5: Show it in the toolbar**

`RightPaneView.devicesActions(rps:)`: before the simulator `guard`, read the state once and return Android's actions for a ready Android device:

```swift
        let tabState = state.devicesTabState(worktree: worktree, selection: rps.devicesSelection)
        if case .android(let target, .ready) = tabState.stage, let device = target.device {
            return AnyView(AndroidActions(device: device, pane: state.androidPane, recorder: state.deviceRecorder) {
                Task {
                    await state.androidPane.shutDown(device)
                    // Back to the AVD's row, to boot it again.
                    rps.devicesSelection = target.avdName.map { .android(AndroidListing.avdID($0)) }
                }
            })
        }
        guard case .simulator(let device, let stage) = tabState.stage else { return nil }
```

- [ ] **Step 6: Build**

`xcodegen`, then `xcodebuild … -quiet build` → succeeds.

- [ ] **Step 7: Commit**

Stage the new-file hunks of the pbxproj only, then:

```bash
git add Alas/Sources/Devices/Android Alas/Sources/Devices/DeviceScreenshot.swift Alas/Sources/App/AppState.swift \
  Alas/Sources/Right/RightPaneView.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(android): screenshot, record and shut down Android devices from the toolbar"
```

---

### Task 9: Docs and the end-to-end pass

**Files:**
- Modify: `docs/devices.md`
- Modify: `docs/plans/2026-11-04-device-panel-design.md`

- [ ] **Step 1: Docs**

`docs/devices.md`: a new `## Android` section after `## Simulators`:

> Android devices need the Android SDK: Android Studio, or the command-line
> tools with `platform-tools` and `emulator`. Alas finds it through
> `ANDROID_HOME`, `ANDROID_SDK_ROOT` or `~/Library/Android/sdk`, and installs
> nothing itself.
>
> The device switcher's Android section lists connected phones and running
> emulators, then the AVDs you can boot. Alas boots an AVD without the
> emulator's window; it keeps running after Alas quits, as simulators do. A
> phone shows once it's connected with USB debugging allowed.
>
> Click to tap, drag to swipe, scroll, and type while the screen has focus.
> The buttons beside the screen are Back, Home, Recents, Power, volume and
> rotation. ⌘V pastes the Mac clipboard's text into the focused field; ⌘C
> copies the device's selection. Drop an `.apk` on the screen to install and
> open it. The toolbar records up to 3 minutes of the screen and saves a
> screenshot, both to the Desktop, and shuts an emulator down.
>
> The screen streams with scrcpy's server, which Alas bundles and copies to
> the device each time it shows the screen.

Device panel design: tick phase 3's outline as built — under `## Phase 3 outline: Android`, add a first line `Built as G (`2026-11-15-devices-android-design.md`); agent tools (H) and settings (I) follow.`

- [ ] **Step 2: End-to-end on the AVD**

With `Medium_Phone_API_36.1` shut down, launch Alas Dev and:
1. The Android section lists it; Boot boots it (about 20 s) and the screen appears.
2. Click Settings' rows, drag to scroll, scroll with the trackpad (check the direction), type in the search field, Back/Home/Recents from the gutter.
3. Rotate left and right: the stage re-fits, touches land.
4. ⌘V into the search field; select text and ⌘C.
5. Screenshot and a short recording land on the Desktop.
6. Drop an `.apk` (any debug build, e.g. from `~/AndroidStudioProjects`) and it opens.
7. Kill Alas while streaming, relaunch: the screen starts again (stale server killed, jar pushed).
8. Shut Down returns to the AVD's row.

Take a screenshot of the Devices tab as proof (`screencapture -l <window id>`). Note any step that couldn't run, and why.

- [ ] **Step 3: Lint and commit**

```bash
swiftformat Alas AlasTests Packages --lint
git add docs/devices.md docs/plans/2026-11-04-device-panel-design.md
git commit -m "docs(android): describe Android devices in the Devices tab"
```
