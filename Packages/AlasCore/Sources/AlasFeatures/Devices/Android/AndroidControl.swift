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
