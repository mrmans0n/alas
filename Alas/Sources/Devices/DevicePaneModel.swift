import AlasCore
import AppKit
import Foundation
import Observation

/// The simulators on this Mac, shared by every worktree's Devices tab, and
/// what each looks like. Which device a tab shows is the worktree's own
/// (`RightPaneState.devicesSelection`).
@MainActor
@Observable
final class DevicePaneModel {
    private(set) var devices: [SimulatorDevice]?
    private(set) var listError: String?
    private(set) var bootingUDIDs: Set<String> = []
    /// The last boot or shutdown failure of each simulator.
    private(set) var errors: [String: String] = [:]
    /// Whether Xcode's `simctl` was found; nil until `checkTools()` finishes.
    private(set) var simulatorToolsFound: Bool?
    /// Screen shapes by device type identifier, read once.
    private(set) var shapes: [String: DeviceScreenShape] = [:]

    enum AppInstall: Equatable {
        case installing(String)
        case launching(String)
        case failed(String)
    }

    /// The app the user dropped on each simulator, while it installs and
    /// launches, or after it failed.
    private(set) var appInstalls: [String: AppInstall] = [:]

    @ObservationIgnored private var toolsCheck: Task<Void, Never>?

    func shape(for device: SimulatorDevice) -> DeviceScreenShape? {
        device.deviceTypeIdentifier.flatMap { shapes[$0] }
    }

    func installAndLaunch(_ url: URL, on device: SimulatorDevice) async {
        let app: SimulatorAppBundle
        do {
            app = try SimulatorAppBundle.read(url)
        } catch {
            appInstalls[device.udid] = .failed(error.localizedDescription)
            return
        }
        appInstalls[device.udid] = .installing(app.name)
        do {
            try await SimulatorControl.install(udid: device.udid, app: app.url)
            appInstalls[device.udid] = .launching(app.name)
            _ = try await SimulatorControl.launch(udid: device.udid, bundleID: app.bundleID)
            appInstalls[device.udid] = nil
        } catch {
            appInstalls[device.udid] = .failed("Couldn't open \(app.name): \(error.localizedDescription)")
        }
    }

    func dismissAppInstall(udid: String) {
        appInstalls[udid] = nil
    }

    /// Shows why an app couldn't be installed, in the simulator's app pill.
    func failAppInstall(udid: String, message: String) {
        appInstalls[udid] = .failed(message)
    }

    /// A short message on each simulator's screen, after a copy or paste.
    private(set) var notices: [String: String] = [:]
    @ObservationIgnored private var noticeTasks: [String: Task<Void, Never>] = [:]

    /// Pastes the Mac clipboard's text into the simulator's focused field.
    func paste(_ text: String?, udid: String, pasteboard: DevicePasteboard) async {
        guard let text, !text.isEmpty else { return show("The clipboard has no text to paste.", udid: udid) }
        guard text.utf8.count <= 1_000_000 else { return show("That text is too long to paste.", udid: udid) }
        do {
            let paste = try await pasteboard.open(udid: udid, keepText: false)
            do { try await pasteboard.paste(text, in: paste) } catch {
                await pasteboard.close(paste)
                return show("Couldn't paste: \(error.localizedDescription)", udid: udid)
            }
            await pasteboard.close(paste)
        } catch {
            show("Couldn't paste: \(error.localizedDescription)", udid: udid)
        }
    }

    /// Copies the simulator's selection to the Mac clipboard.
    func copy(udid: String, pasteboard: DevicePasteboard) async {
        do {
            guard let text = try await pasteboard.copy(udid: udid) else {
                return show("Nothing was copied. Select some text first.", udid: udid)
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            show("Copied", udid: udid)
        } catch {
            show("Couldn't copy: \(error.localizedDescription)", udid: udid)
        }
    }

    private func show(_ notice: String, udid: String) {
        notices[udid] = notice
        noticeTasks[udid]?.cancel()
        noticeTasks[udid] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.notices[udid] = nil
        }
    }

    /// A simulator that was booted isn't any more; its recording ends.
    @ObservationIgnored var onShutDown: (String) -> Void = { _ in }

    func refresh() async {
        do {
            let before = Set((devices ?? []).filter { $0.state == .booted }.map(\.udid))
            devices = try await SimulatorControl.devices()
            let booted = Set((devices ?? []).filter { $0.state == .booted }.map(\.udid))
            before.subtracting(booted).forEach(onShutDown)
            listError = nil
        } catch {
            listError = error.localizedDescription
        }
    }

    /// Keeps the list current while a Devices tab is visible, so a device shut
    /// down or deleted elsewhere does not leave a frozen screen.
    func pollWhileVisible() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(3))
        }
    }

    func boot(_ device: SimulatorDevice) async {
        errors[device.udid] = nil
        bootingUDIDs.insert(device.udid)
        do {
            try await SimulatorControl.boot(udid: device.udid)
        } catch {
            errors[device.udid] = error.localizedDescription
        }
        await refresh()
        bootingUDIDs.remove(device.udid)
    }

    func shutDown(_ device: SimulatorDevice) async {
        errors[device.udid] = nil
        do {
            try await SimulatorControl.shutdown(udid: device.udid)
        } catch {
            errors[device.udid] = error.localizedDescription
        }
        await refresh()
    }

    /// Looks for the simulator tools and reads the device shapes, once.
    func checkTools() async {
        if toolsCheck == nil { toolsCheck = Task { await loadTools() } }
        await toolsCheck?.value
    }

    private func loadTools() async {
        let found = await SimulatorControl.isAvailable()
        simulatorToolsFound = found
        guard found, let bundles = try? await SimulatorControl.deviceTypeBundles() else { return }
        // Small plist and JSON reads, off the main actor.
        shapes = await Task.detached {
            bundles.compactMapValues { DeviceScreenShape.load(bundle: $0) }
        }.value
    }
}
