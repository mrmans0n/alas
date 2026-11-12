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
        if await !isInstalled(udid: udid, bundleID: bundleID) { throw SimulatorLaunchError.notInstalled }
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

    public static func isInstalled(udid: String, bundleID: String) async -> Bool {
        (try? await Process.run(xcrun, args: ["simctl", "get_app_container", udid, bundleID]))?.exitCode == 0
    }

    /// Runs `simctl ui <udid> <option> <value>`.
    static func ui(udid: String, _ option: String, _ value: String) async throws {
        let result = try await Process.run(xcrun, args: ["simctl", "ui", udid, option, value])
        guard result.exitCode == 0 else { throw SimulatorControlError(result) }
    }

    public static func display(udid: String) async throws -> SimulatorDisplaySettings {
        func read(_ option: String) async throws -> String {
            let result = try await Process.run(xcrun, args: ["simctl", "ui", udid, option])
            guard result.exitCode == 0 else { throw SimulatorControlError(result) }
            return result.stdout
        }
        return SimulatorDisplaySettings.parse(
            appearance: try await read("appearance"),
            contentSize: try await read("content_size"),
            increaseContrast: try await read("increase_contrast")
        )
    }

    public static func privacy(
        udid: String, action: SimulatorPrivacyAction, service: SimulatorPrivacyService, bundleID: String
    ) async throws {
        let result = try await Process.run(xcrun, args: ["simctl", "privacy", udid, action.rawValue, service.rawValue, bundleID])
        guard result.exitCode == 0 else { throw SimulatorControlError(result) }
    }

    /// Sets the simulated location, or clears it when `location` is nil.
    public static func location(udid: String, _ location: SimulatorLocation?) async throws {
        let args = location.map { ["simctl", "location", udid, "set", "\($0.latitude),\($0.longitude)"] }
            ?? ["simctl", "location", udid, "clear"]
        let result = try await Process.run(xcrun, args: args)
        guard result.exitCode == 0 else { throw SimulatorControlError(result) }
    }

    public static func push(udid: String, bundleID: String, payload: Data) async throws {
        let result = try await Process.run(
            xcrun, args: ["simctl", "push", udid, bundleID, "-"], stdin: String(decoding: payload, as: UTF8.self)
        )
        guard result.exitCode == 0 else { throw SimulatorControlError(result) }
    }

    public static func openURL(udid: String, url: String) async throws {
        let result = try await Process.run(xcrun, args: ["simctl", "openurl", udid, url])
        guard result.exitCode == 0 else { throw SimulatorControlError(result) }
    }

    public static func userApps(udid: String) async throws -> [SimulatorApp] {
        let result = try await Process.run(xcrun, args: ["simctl", "listapps", udid])
        guard result.exitCode == 0 else { throw SimulatorControlError(result) }
        return SimulatorAppList.parse(Data(result.stdout.utf8))
    }

    public static func appExecutables(udid: String) async throws -> [String: String] {
        let result = try await Process.run(xcrun, args: ["simctl", "listapps", udid])
        guard result.exitCode == 0 else { throw SimulatorControlError(result) }
        return SimulatorAppList.executables(Data(result.stdout.utf8))
    }

    /// The archived log lines of the last `seconds`, oldest first.
    public static func logShow(udid: String, query: SimulatorLogQuery, seconds: Int) async throws -> [SimulatorLogLine] {
        var args = ["simctl", "spawn", udid, "log", "show", "--last", "\(seconds)s", "--style", "ndjson"] + query.showArguments
        if let predicate = query.predicate { args += ["--predicate", predicate] }
        let result = try await Process.run(xcrun, args: args, timeout: 90)
        guard result.exitCode == 0 else { throw SimulatorControlError(result) }
        return result.stdout.split(separator: "\n").compactMap { SimulatorLogLine.parse(Data($0.utf8)) }
    }

    public static let diagnosticReports = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)

    /// The simulator's app crash reports written since `since`, oldest first.
    public static func crashReports(
        udid: String, bundleID: String?, since: Date, directory: URL = diagnosticReports
    ) -> [SimulatorCrashReport] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles
        )) ?? []
        return files
            .filter { $0.pathExtension == "ips" }
            .filter {
                ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) >= since
            }
            .compactMap { url -> SimulatorCrashReport? in
                guard let data = try? Data(contentsOf: url), var report = SimulatorCrashReport.parse(data, udid: udid),
                      bundleID == nil || report.bundleID == bundleID
                else { return nil }
                report.report = url.path
                return report
            }
            .sorted { $0.capturedAt < $1.capturedAt }
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
