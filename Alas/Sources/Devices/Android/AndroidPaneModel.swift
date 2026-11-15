import AlasCore
import AppKit
import Foundation
import Observation

/// The Android devices and AVDs on this Mac, shared by every worktree's
/// Devices tab.
@MainActor
@Observable
final class AndroidPaneModel {
    /// The user's SDK, found when Alas starts; nil when there is none.
    let control: AndroidControl? = AndroidSDK.locate().map(AndroidControl.init)
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

    /// What the Devices tab lists; nil while the first list loads.
    var listing: AndroidListing? {
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
        // A second Boot while the first runs would start the AVD twice.
        guard bootingAVDs.insert(avd).inserted else { return }
        let id = AndroidListing.avdID(avd)
        errors[id] = nil
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
