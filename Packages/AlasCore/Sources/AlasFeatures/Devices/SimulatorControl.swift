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

/// Lists and boots simulators with `xcrun simctl`, which is public API.
/// Capture and input go through AlasSimService instead.
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
}
