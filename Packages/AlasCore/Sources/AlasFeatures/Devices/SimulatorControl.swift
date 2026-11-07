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

/// Lists, boots and shuts down simulators with `xcrun simctl`, which is public
/// API. Capture and input go through AlasSimService instead.
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
