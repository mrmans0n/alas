import Darwin
import Foundation

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

    /// Clones a sealed golden bundle into `to`. Disk and auxiliary storage use
    /// `clonefile(2)` (APFS copy-on-write); the hardware model is copied and a
    /// fresh machine identifier and MAC address are written. The work happens
    /// in `<to>.partial` and is renamed into place on success.
    public static func cloneForWorktree(
        golden: VMBundle, to: URL, newMachineIdentifier: Data, newMACAddress: String
    ) throws -> VMBundle {
        guard golden.isSealed else {
            throw CloneError(description: "Golden VM bundle at \(golden.url.path) is not sealed")
        }
        let fm = FileManager.default
        let partial = to.appendingPathExtension("partial")
        try? fm.removeItem(at: partial)
        try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try fm.createDirectory(at: partial, withIntermediateDirectories: false)
            let staged = VMBundle(url: partial)
            try cloneFile(golden.diskImage, to: staged.diskImage)
            try cloneFile(golden.auxiliaryStorage, to: staged.auxiliaryStorage)
            try fm.copyItem(at: golden.hardwareModel, to: staged.hardwareModel)
            try newMachineIdentifier.write(to: staged.machineIdentifier)
            try Data(newMACAddress.utf8).write(to: staged.macAddress)
            try fm.moveItem(at: partial, to: to)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        return VMBundle(url: to)
    }

    private static func cloneFile(_ src: URL, to dst: URL) throws {
        if clonefile(src.path, dst.path, 0) != 0 {
            let code = errno
            throw NSError(
                domain: NSPOSIXErrorDomain, code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: "clonefile \(src.lastPathComponent): \(String(cString: strerror(code)))"])
        }
    }
}
