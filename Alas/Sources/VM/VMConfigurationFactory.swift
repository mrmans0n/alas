import AlasCore
import Foundation
import Virtualization

/// Guest display geometry, persisted per VM.
struct VMDisplaySize: Codable, Equatable, Sendable {
    var width: Int
    var height: Int
    var pixelsPerInch: Int

    static let `default` = VMDisplaySize(width: 1920, height: 1200, pixelsPerInch: 144)
}

/// Builds Virtualization.framework configurations from on-disk VM bundles.
enum VMConfigurationFactory {
    struct ConfigurationError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let gib: UInt64 = 1 << 30

    /// A macOS guest: hardware model, machine identifier and auxiliary storage
    /// come from the bundle, plus a virtio disk, NAT networking with the
    /// bundle's MAC address, a display, keyboard, trackpad and a vsock device.
    /// No audio device is attached.
    static func macOS(
        bundle: VMBundle, cpuCount: Int, memoryBytes: UInt64, display: VMDisplaySize
    ) throws -> VZVirtualMachineConfiguration {
        let platform = VZMacPlatformConfiguration()
        guard let hardwareModel = VZMacHardwareModel(
            dataRepresentation: try Data(contentsOf: bundle.hardwareModel))
        else {
            throw ConfigurationError(message: "Invalid hardware model in \(bundle.url.path)")
        }
        guard hardwareModel.isSupported else {
            throw ConfigurationError(message: "The VM hardware model is not supported on this Mac")
        }
        platform.hardwareModel = hardwareModel
        guard let machineIdentifier = VZMacMachineIdentifier(
            dataRepresentation: try Data(contentsOf: bundle.machineIdentifier))
        else {
            throw ConfigurationError(message: "Invalid machine identifier in \(bundle.url.path)")
        }
        platform.machineIdentifier = machineIdentifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: bundle.auxiliaryStorage)

        let macString = try String(contentsOf: bundle.macAddress, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let macAddress = VZMACAddress(string: macString) else {
            throw ConfigurationError(message: "Invalid MAC address in \(bundle.url.path)")
        }

        let configuration = VZVirtualMachineConfiguration()
        configuration.platform = platform
        configuration.bootLoader = VZMacOSBootLoader()
        configuration.cpuCount = cpuCount
        configuration.memorySize = memoryBytes

        let disk = try VZDiskImageStorageDeviceAttachment(url: bundle.diskImage, readOnly: false)
        configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]

        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        network.macAddress = macAddress
        configuration.networkDevices = [network]

        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [
            VZMacGraphicsDisplayConfiguration(
                widthInPixels: display.width, heightInPixels: display.height,
                pixelsPerInch: display.pixelsPerInch),
        ]
        configuration.graphicsDevices = [graphics]
        configuration.keyboards = [VZUSBKeyboardConfiguration()]
        configuration.pointingDevices = [VZMacTrackpadConfiguration()]
        configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]

        try configuration.validate()
        return configuration
    }

    /// Half the host CPUs (2...8) and a quarter of its memory (4...16 GiB),
    /// rounded down to a whole GiB.
    static func defaultResources(hostCPUs: Int, hostMemory: UInt64) -> (cpus: Int, memory: UInt64) {
        let cpus = min(max(hostCPUs / 2, 2), 8)
        let memory = min(max(hostMemory / 4, 4 * gib), 16 * gib)
        return (cpus, memory / gib * gib)
    }
}
