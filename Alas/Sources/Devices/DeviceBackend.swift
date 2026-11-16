import AlasCore
import Foundation

/// Why a backend can't do something; the control answers `message` as is.
struct DeviceToolError: Error, LocalizedError {
    let message: String

    var errorDescription: String? { message }

    static func unsupported(_ tool: String) -> DeviceToolError {
        DeviceToolError(message: "device_unsupported: \(tool) isn't available on Android.")
    }
}

/// The app isn't installed; the control names the device.
struct DeviceAppNotInstalled: Error {
    let appID: String
}

/// One platform's devices, for `DeviceAgentControl`: everything the `device_*`
/// tools do that depends on the platform.
@MainActor
protocol DeviceBackend: AnyObject {
    var platform: AgentDevice.Platform { get }
    /// Frames, touches, keys, and the stream an agent's lease keeps open.
    var input: DeviceInput { get }
    func devices() async throws -> [AgentDevice]
    /// Boots `id` and returns the id to use from then on.
    func boot(_ id: String) async throws -> String
    func snapshot(_ id: String, generation: Int) async throws -> DeviceSnapshot
    /// False when the platform has no such button.
    func press(_ id: String, _ button: DeviceCommand.Button) -> Bool
    /// Turns the device and returns the interface orientation shown.
    func rotate(_ id: String, to orientation: DeviceScreenOrientation) async throws -> DeviceScreenOrientation
    func beginPaste(_ id: String) async throws -> any DevicePasteSession
    func readClipboard(_ id: String) async throws -> String
    func writeClipboard(_ id: String, _ text: String) async throws
    /// The app's id and name; a bad file throws `DeviceToolError` with its device_* code.
    func install(_ id: String, path: String) async throws -> (appID: String, name: String)
    /// The launched app's pid; `DeviceAppNotInstalled` when it isn't there.
    func launch(_ id: String, appID: String) async throws -> Int
    func isInstalled(_ id: String, appID: String) async -> Bool
    func openURL(_ id: String, _ url: String) async throws
    func setDisplay(
        _ id: String, appearance: SimulatorAppearance?, textSize: SimulatorTextSize?, increaseContrast: Bool?
    ) async throws -> SimulatorDisplaySettings
    func setAccessibility(_ id: String, _ change: SimulatorAccessibilityChange) async throws -> SimulatorAccessibility
    func setPermission(_ id: String, appID: String, service: SimulatorPrivacyService, action: SimulatorPrivacyAction) async throws
    func setLocation(_ id: String, _ location: SimulatorLocation?) async throws
    func push(_ id: String, appID: String, payload: Data) async throws
    /// device_logs' reply; `name` is the device's, for messages.
    func logs(
        _ id: String, name: String, since: Int, appID: String?, level: SimulatorLogLevel, includeApple: Bool,
        query: String?, limit: Int
    ) async throws -> [String: Any]
}

/// Text pasted into the focused field, with the clipboard put back by `end`.
@MainActor
protocol DevicePasteSession: AnyObject {
    func paste(_ text: String) async throws
    func end() async
}
