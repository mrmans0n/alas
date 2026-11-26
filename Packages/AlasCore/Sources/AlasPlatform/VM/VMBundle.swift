import Foundation
import AlasFoundation

/// On-disk layout of a VM: a directory of fixed-name files. Golden images are
/// sealed once setup finishes; worktree VMs are copy-on-write clones of them.
public struct VMBundle: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public var diskImage: URL { url.appendingPathComponent("disk.img") }
    public var auxiliaryStorage: URL { url.appendingPathComponent("aux.img") }
    public var hardwareModel: URL { url.appendingPathComponent("hw.bin") }
    public var machineIdentifier: URL { url.appendingPathComponent("machine-id.bin") }
    public var macAddress: URL { url.appendingPathComponent("mac.txt") }
    public var sealedMarker: URL { url.appendingPathComponent(".sealed") }

    public var isSealed: Bool {
        FileManager.default.fileExists(atPath: sealedMarker.path)
    }

    public struct CloneError: Error, Sendable, CustomStringConvertible {
        public let description: String
    }

    public struct CloneIdentity: Sendable {
        public let machineIdentifier: Data
        public let macAddress: String

        public init(machineIdentifier: Data, macAddress: String) {
            self.machineIdentifier = machineIdentifier
            self.macAddress = macAddress
        }
    }

    /// Copies only the boot files. A nil identity makes a nonbootable base.
    /// The caller must hold the source stable and confirm its disk is clean.
    public static func stageClone(from source: VMBundle, to: URL, identity: CloneIdentity?) throws -> VMBundle {
        try stageClone(from: source, to: to, identity: identity, disk: source.diskImage, auxiliary: source.auxiliaryStorage)
    }

    /// Clones a sealed golden bundle into `to`. Disk and auxiliary storage use
    /// `clonefile(2)` (APFS copy-on-write); the hardware model is copied and a
    /// fresh machine identifier and MAC address are written. The work happens
    /// in `<to>.partial` and is renamed into place on success. `diskFrom` and
    /// `auxiliaryStorageFrom` replace the golden's files, for a clone of a project template.
    public static func cloneForWorktree(
        golden: VMBundle, to: URL, newMachineIdentifier: Data, newMACAddress: String,
        diskFrom: URL? = nil, auxiliaryStorageFrom: URL? = nil
    ) throws -> VMBundle {
        guard golden.isSealed else {
            throw CloneError(description: "Golden VM bundle at \(golden.url.path) is not sealed")
        }
        return try stageClone(
            from: golden, to: to, identity: CloneIdentity(machineIdentifier: newMachineIdentifier, macAddress: newMACAddress),
            disk: diskFrom ?? golden.diskImage, auxiliary: auxiliaryStorageFrom ?? golden.auxiliaryStorage)
    }

    private static func stageClone(
        from source: VMBundle, to: URL, identity: CloneIdentity?, disk: URL, auxiliary: URL
    ) throws -> VMBundle {
        let fm = FileManager.default
        let partial = to.appendingPathExtension("partial")
        try? fm.removeItem(at: partial)
        try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try fm.createDirectory(at: partial, withIntermediateDirectories: false)
            let staged = VMBundle(url: partial)
            try cloneFile(disk, to: staged.diskImage)
            try cloneFile(auxiliary, to: staged.auxiliaryStorage)
            try fm.copyItem(at: source.hardwareModel, to: staged.hardwareModel)
            if let identity {
                try identity.machineIdentifier.write(to: staged.machineIdentifier)
                try Data(identity.macAddress.utf8).write(to: staged.macAddress)
            }
            try fm.moveItem(at: partial, to: to)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        return VMBundle(url: to)
    }

    /// Copies `src` to `dst` with `clonefile(2)`: copy-on-write on APFS, and
    /// an error across volumes.
    public static func cloneFile(_ src: URL, to dst: URL) throws {
        #if canImport(Darwin)
        let failed = clonefile(src.path, dst.path, 0) != 0
        #else
        let failed = true // VM bundles live only on macOS.
        errno = ENOTSUP
        #endif
        if failed {
            let code = errno
            throw NSError(
                domain: NSPOSIXErrorDomain, code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: "clonefile \(src.lastPathComponent): \(String(cString: strerror(code)))"])
        }
    }
}
