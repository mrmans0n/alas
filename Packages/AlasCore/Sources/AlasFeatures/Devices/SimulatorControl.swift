import AlasPlatform
import Foundation

public struct SimulatorControlError: Error, LocalizedError, Equatable {
    public let message: String

    init(_ result: ProcessResult) {
        let output = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        message = output.isEmpty ? "simctl exited with status \(result.exitCode)" : output
    }

    public var errorDescription: String? { message }
}

public enum SimulatorLaunchError: Error, Equatable, LocalizedError {
    case notInstalled

    public var errorDescription: String? { "The app isn't installed on this simulator." }
}

/// Lists, boots and shuts down simulators, and installs and launches apps,
/// with `xcrun simctl`, which is public API. Capture and input go through
/// AlasSimService instead.
public enum SimulatorControl {
    private static let xcrun = "/usr/bin/xcrun"

    public static func devices() async throws -> [SimulatorDevice] {
        let result = try await Process.run(xcrun, args: ["simctl", "list", "devices", "--json"])
        guard result.exitCode == 0 else { throw SimulatorControlError(result) }
        return try SimulatorDeviceList.parse(Data(result.stdout.utf8))
    }

    /// Returns once the device has finished booting.
    public static func boot(udid: String) async throws {
        let boot = try await Process.run(xcrun, args: ["simctl", "boot", udid])
        // A device that booted in the meantime answers
        // "Unable to boot device in current state: Booted".
        guard boot.exitCode == 0 || boot.stderr.contains("current state: Booted") else {
            throw SimulatorControlError(boot)
        }
        let status = try await Process.run(xcrun, args: ["simctl", "bootstatus", udid, "-b"], timeout: 300)
        guard status.exitCode == 0 else { throw SimulatorControlError(status) }
    }

    public static func shutdown(udid: String) async throws {
        let result = try await Process.run(xcrun, args: ["simctl", "shutdown", udid], timeout: 60)
        // A device that was already shut down answers "… in current state: Shutdown".
        guard result.exitCode == 0 || result.stderr.contains("current state: Shutdown") else {
            throw SimulatorControlError(result)
        }
    }

    /// Installs a built `.app`, replacing an installed copy.
    public static func install(udid: String, app: URL) async throws {
        let result = try await Process.run(xcrun, args: ["simctl", "install", udid, app.path], timeout: 90)
        guard result.exitCode == 0 else { throw SimulatorControlError(result) }
    }

    /// Launches an installed app, ending a running copy first, and returns its pid.
    public static func launch(udid: String, bundleID: String) async throws -> Int32 {
        let result = try await Process.run(
            xcrun, args: ["simctl", "launch", "--terminate-running-process", udid, bundleID], timeout: 60
        )
        if result.exitCode == 0, let pid = launchedPID(result.stdout, bundleID: bundleID) { return pid }
        // simctl's launch error doesn't say the app is missing; its container lookup does.
        let container = try await Process.run(xcrun, args: ["simctl", "get_app_container", udid, bundleID])
        if container.exitCode != 0 { throw SimulatorLaunchError.notInstalled }
        throw SimulatorControlError(result)
    }

    /// simctl launch prints `<bundle id>: <pid>`.
    public static func launchedPID(_ stdout: String, bundleID: String) -> Int32? {
        for line in stdout.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0] == bundleID {
                return Int32(parts[1].trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    /// Whether Xcode's simulator tools are installed and selected.
    public static func isAvailable() async -> Bool {
        (try? await Process.run(xcrun, args: ["--find", "simctl"]))?.exitCode == 0
    }

    /// Each simulator device type's bundle, by identifier.
    public static func deviceTypeBundles() async throws -> [String: URL] {
        struct Listing: Decodable {
            struct DeviceType: Decodable {
                let identifier: String
                let bundlePath: String?
            }
            let devicetypes: [DeviceType]
        }
        let result = try await Process.run(xcrun, args: ["simctl", "list", "devicetypes", "--json"])
        guard result.exitCode == 0 else { throw SimulatorControlError(result) }
        let listing = try JSONDecoder().decode(Listing.self, from: Data(result.stdout.utf8))
        var bundles: [String: URL] = [:]
        for type in listing.devicetypes {
            if let path = type.bundlePath { bundles[type.identifier] = URL(fileURLWithPath: path) }
        }
        return bundles
    }
}
