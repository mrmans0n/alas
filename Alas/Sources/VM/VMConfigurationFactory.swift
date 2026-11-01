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

/// A host directory shared with the guest. macOS guests mount every share
/// under `/Volumes/My Shared Files/<name>`.
struct VMShare: Equatable, Sendable {
    var name: String
    var hostURL: URL
    var readOnly: Bool
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
    /// bundle's MAC address, a display, keyboard, trackpad, a vsock device and,
    /// when `shares` is not empty, one auto-mounted virtio file system holding
    /// them all. No audio device is attached. Throws on Intel, which cannot
    /// run macOS guests.
    static func macOS(
        bundle: VMBundle, cpuCount: Int, memoryBytes: UInt64, display: VMDisplaySize, shares: [VMShare] = []
    ) throws -> VZVirtualMachineConfiguration {
        #if !arch(arm64)
        throw ConfigurationError(message: WorktreeVMManager.unsupportedMessage)
        #else
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
        if !shares.isEmpty {
            let fileSystem = VZVirtioFileSystemDeviceConfiguration(
                tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
            fileSystem.share = VZMultipleDirectoryShare(directories: Dictionary(
                shares.map { ($0.name, VZSharedDirectory(url: $0.hostURL, readOnly: $0.readOnly)) },
                uniquingKeysWith: { first, _ in first }))
            configuration.directorySharingDevices = [fileSystem]
        }

        try configuration.validate()
        return configuration
        #endif
    }

    /// A Linux guest booted through EFI: the bundle's variable store, generic
    /// machine identifier and MAC address, a cached virtio disk, the seed ISO
    /// read-only when given, a virtio GPU with one scanout, a USB keyboard and
    /// absolute pointer, a vsock device, an entropy device, a SPICE agent
    /// console port for the clipboard, the serial console in the bundle's
    /// `console.log` and, when `shares` is not empty, one virtio file system
    /// tagged `alas` holding them all. No audio device is attached.
    static func linux(
        bundle: LinuxVMBundle, cpuCount: Int, memoryBytes: UInt64, display: VMDisplaySize,
        shares: [VMShare], seedISO: URL?
    ) throws -> VZVirtualMachineConfiguration {
        #if !arch(arm64)
        throw ConfigurationError(message: WorktreeVMManager.unsupportedMessage)
        #else
        guard let machineIdentifier = VZGenericMachineIdentifier(
            dataRepresentation: try Data(contentsOf: bundle.machineIdentifier))
        else {
            throw ConfigurationError(message: "Invalid machine identifier in \(bundle.url.path)")
        }
        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = machineIdentifier

        let macString = try String(contentsOf: bundle.macAddress, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let macAddress = VZMACAddress(string: macString) else {
            throw ConfigurationError(message: "Invalid MAC address in \(bundle.url.path)")
        }

        let configuration = VZVirtualMachineConfiguration()
        configuration.platform = platform
        let bootLoader = VZEFIBootLoader()
        bootLoader.variableStore = VZEFIVariableStore(url: bundle.efiVariableStore)
        configuration.bootLoader = bootLoader
        configuration.cpuCount = cpuCount
        configuration.memorySize = memoryBytes

        let disk = try VZDiskImageStorageDeviceAttachment(
            url: bundle.diskImage, readOnly: false, cachingMode: .cached, synchronizationMode: .full)
        var storage = [VZStorageDeviceConfiguration](arrayLiteral: VZVirtioBlockDeviceConfiguration(attachment: disk))
        if let seedISO {
            let seed = try VZDiskImageStorageDeviceAttachment(url: seedISO, readOnly: true)
            storage.append(VZVirtioBlockDeviceConfiguration(attachment: seed))
        }
        configuration.storageDevices = storage

        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        network.macAddress = macAddress
        configuration.networkDevices = [network]

        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [
            VZVirtioGraphicsScanoutConfiguration(widthInPixels: display.width, heightInPixels: display.height),
        ]
        configuration.graphicsDevices = [graphics]
        configuration.keyboards = [VZUSBKeyboardConfiguration()]
        configuration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]

        let console = VZVirtioConsoleDeviceConfiguration()
        let spice = VZVirtioConsolePortConfiguration()
        spice.name = VZSpiceAgentPortAttachment.spiceAgentPortName
        let agent = VZSpiceAgentPortAttachment()
        agent.sharesClipboard = true
        spice.attachment = agent
        console.ports[0] = spice
        configuration.consoleDevices = [console]

        // Ubuntu cloud images log the kernel and cloud-init to hvc0.
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = try VZFileSerialPortAttachment(url: bundle.consoleLog, append: false)
        configuration.serialPorts = [serial]
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        if !shares.isEmpty {
            let fileSystem = VZVirtioFileSystemDeviceConfiguration(tag: LinuxCloudInit.shareTag)
            fileSystem.share = VZMultipleDirectoryShare(directories: Dictionary(
                shares.map { ($0.name, VZSharedDirectory(url: $0.hostURL, readOnly: $0.readOnly)) },
                uniquingKeysWith: { first, _ in first }))
            configuration.directorySharingDevices = [fileSystem]
        }

        try configuration.validate()
        return configuration
        #endif
    }

    /// Half the host CPUs (2...8) and a quarter of its memory (4...16 GiB),
    /// rounded down to a whole GiB.
    static func defaultResources(hostCPUs: Int, hostMemory: UInt64) -> (cpus: Int, memory: UInt64) {
        let cpus = min(max(hostCPUs / 2, 2), 8)
        let memory = min(max(hostMemory / 4, 4 * gib), 16 * gib)
        return (cpus, memory / gib * gib)
    }
}
