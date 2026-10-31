import AlasCore
import Foundation
#if arch(arm64)
import Virtualization
#endif

/// On-disk layout of a Linux VM: a raw disk, its EFI variable store, a
/// generic machine identifier and a MAC address. Golden images are sealed
/// once their first start finished; worktree VMs are copy-on-write clones.
struct LinuxVMBundle: Sendable {
    let url: URL

    var diskImage: URL { url.appendingPathComponent("disk.img") }
    var efiVariableStore: URL { url.appendingPathComponent("efi-vars.fd") }
    var machineIdentifier: URL { url.appendingPathComponent("machine-id.bin") }
    var macAddress: URL { url.appendingPathComponent("mac.txt") }
    var sealedMarker: URL { url.appendingPathComponent(".sealed") }

    var isSealed: Bool { FileManager.default.fileExists(atPath: sealedMarker.path) }

    struct BundleError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    #if arch(arm64)
    /// Writes a fresh EFI variable store, machine identifier and MAC address
    /// beside a disk image already at `diskImage`.
    func writeIdentity() throws {
        _ = try VZEFIVariableStore(creatingVariableStoreAt: efiVariableStore, options: [.allowOverwrite])
        try VZGenericMachineIdentifier().dataRepresentation.write(to: machineIdentifier)
        try Data(VZMACAddress.randomLocallyAdministered().string.utf8).write(to: macAddress)
    }

    /// Clones a sealed golden bundle into `to`: the disk with `clonefile(2)`
    /// (APFS copy-on-write) and a fresh identity, so the clone boots as a new
    /// machine with its own DHCP lease. The work happens in `<to>.partial`
    /// and is renamed into place on success.
    static func cloneForWorktree(golden: LinuxVMBundle, to: URL) throws -> LinuxVMBundle {
        guard golden.isSealed else {
            throw BundleError(message: "Golden Linux VM bundle at \(golden.url.path) is not sealed")
        }
        let fm = FileManager.default
        let partial = to.appendingPathExtension("partial")
        try? fm.removeItem(at: partial)
        try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try fm.createDirectory(at: partial, withIntermediateDirectories: false)
            let staged = LinuxVMBundle(url: partial)
            try VMBundle.cloneFile(golden.diskImage, to: staged.diskImage)
            try staged.writeIdentity()
            try fm.moveItem(at: partial, to: to)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        return LinuxVMBundle(url: to)
    }
    #endif
}
