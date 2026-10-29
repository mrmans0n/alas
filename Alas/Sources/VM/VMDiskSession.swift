import AlasCore
import Foundation
import os

/// A stopped guest's `disk.img` attached on the host with its APFS Data volume
/// mounted read-write (and the System volume read-only, only to read
/// `SystemVersion.plist`), so `VMGuestPatcher` can edit it offline.
///
/// Mount points live under `<root>/mnt/<uuid>/`, next to an `owner.plist`
/// naming this process and the image, so a later launch can tell a crashed
/// session from one another Alas process (release and dev share the root) is
/// still using. Blocking: call off the main actor. `close()` (or `deinit`)
/// always detaches.
///
/// The attach/inspect/detach sequence follows trycua/cua `libs/lume`
/// `src/Unattended/DiskImageSession.swift` (MIT).
final class VMDiskSession: @unchecked Sendable {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    let dataVolume: URL
    let systemVolume: URL?

    private let wholeDisk: String
    private let sessionDirectory: URL
    private let lock = NSLock()
    private var closed = false

    private static let logger = Logger(subsystem: "io.nlopez.alas", category: "vm-disk-session")
    private static let ownerFileName = "owner.plist"
    private static let attachTimeout: TimeInterval = 120
    private static let detachTimeout: TimeInterval = 60
    /// Session directory names this process has open, so the launch sweep
    /// never takes one of its own live sessions for a crashed one.
    private static let liveSessions = OSAllocatedUnfairLock(initialState: Set<String>())

    private init(dataVolume: URL, systemVolume: URL?, wholeDisk: String, sessionDirectory: URL) {
        self.dataVolume = dataVolume
        self.systemVolume = systemVolume
        self.wholeDisk = wholeDisk
        self.sessionDirectory = sessionDirectory
    }

    deinit { close() }

    static func open(diskImage: URL, root: URL = Paths.vmsRoot) throws -> VMDiskSession {
        let fm = FileManager.default
        let name = UUID().uuidString
        liveSessions.withLock { _ = $0.insert(name) }
        let session = root.appendingPathComponent("mnt/\(name)", isDirectory: true)
        let dataMount = session.appendingPathComponent("data", isDirectory: true)
        let systemMount = session.appendingPathComponent("system", isDirectory: true)
        let imagePath = diskImage.resolvingSymlinksInPath().path

        let attached: [String: Any]
        do {
            // The owner file comes first: a sweep that sees the directory can always tell who owns it.
            try fm.createDirectory(at: session, withIntermediateDirectories: true)
            let owner: [String: Any] = ["pid": Int(getpid()), "image": imagePath]
            try PropertyListSerialization.data(fromPropertyList: owner, format: .xml, options: 0)
                .write(to: session.appendingPathComponent(ownerFileName))
            try fm.createDirectory(at: dataMount, withIntermediateDirectories: false)
            try fm.createDirectory(at: systemMount, withIntermediateDirectories: false)
            attached = try runPlist(
                "/usr/bin/hdiutil", ["attach", "-readwrite", "-nomount", "-plist", diskImage.path], timeout: attachTimeout
            )
        } catch {
            removeSessionDirectory(session)
            throw error
        }
        guard let wholeDisk = Self.wholeDisk(inEntities: attached["system-entities"]) else {
            detachImage(at: imagePath)
            removeSessionDirectory(session)
            throw Failure(message: "hdiutil attached \(diskImage.lastPathComponent) but reported no whole disk")
        }

        var systemMounted = false
        do {
            let container = try apfsContainer(entities: attached["system-entities"], wholeDisk: wholeDisk)
            let volumes = apfsVolumes(inList: try runPlist("/usr/sbin/diskutil", ["apfs", "list", "-plist", container]))
            guard let data = volumes.data else {
                throw Failure(message: "No APFS Data volume in \(container) of \(diskImage.lastPathComponent)")
            }
            // nobrowse keeps Spotlight and Finder out of the guest; noowners
            // lets the host write files the guest sees as its own.
            try run(
                "/usr/sbin/diskutil",
                ["mount", "-mountOptions", "nobrowse,noowners", "-mountPoint", dataMount.path, data],
                timeout: attachTimeout
            )
            let info = try runPlist("/usr/sbin/diskutil", ["info", "-plist", data])
            guard ownershipDisabled(inInfo: info) else {
                unmount(dataMount)
                throw Failure(message: "The guest's Data volume mounted with ownership enabled")
            }
            if let system = volumes.system {
                do {
                    try run(
                        "/usr/sbin/diskutil",
                        ["mount", "readOnly", "-mountOptions", "nobrowse", "-mountPoint", systemMount.path, system],
                        timeout: attachTimeout
                    )
                    systemMounted = true
                } catch {
                    logger.error("system volume mount failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        } catch {
            detach(wholeDisk)
            removeSessionDirectory(session)
            throw error
        }
        return VMDiskSession(
            dataVolume: dataMount, systemVolume: systemMounted ? systemMount : nil,
            wholeDisk: wholeDisk, sessionDirectory: session
        )
    }

    /// The guest's macOS version, from the read-only System volume.
    func systemVersion() throws -> (product: String, build: String) {
        guard let systemVolume else { throw Failure(message: "The guest's System volume is not mounted") }
        let url = systemVolume.appendingPathComponent("System/Library/CoreServices/SystemVersion.plist")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: nil)
        guard let version = plist as? [String: Any],
              let product = version["ProductVersion"] as? String,
              let build = version["ProductBuildVersion"] as? String
        else { throw Failure(message: "Unreadable \(url.path)") }
        return (product, build)
    }

    /// Unmounts both volumes and detaches the image. Safe to call twice.
    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        if let systemVolume { Self.unmount(systemVolume) }
        Self.unmount(dataVolume)
        Self.detach(wholeDisk)
        Self.removeSessionDirectory(sessionDirectory)
    }

    // MARK: - Stale sessions

    /// Detaches images under `root` and removes mount directories left by an
    /// Alas process that died mid-session. Sessions whose owner is still
    /// running are left alone. Blocking: call off the main actor.
    static func detachStaleSessions(under root: URL) {
        let mnt = root.appendingPathComponent("mnt", isDirectory: true)
        let sessions = (try? FileManager.default.contentsOfDirectory(
            at: mnt, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )) ?? []
        // A launch that never opened a session doesn't shell out.
        guard !sessions.isEmpty else { return }

        var liveImages = Set<String>()
        var staleSessions: [URL] = []
        for session in sessions {
            let owner = (try? Data(contentsOf: session.appendingPathComponent(ownerFileName)))
                .flatMap { try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) }
                as? [String: Any]
            let ownSession = liveSessions.withLock { $0.contains(session.lastPathComponent) }
            let ownerPID = owner?["pid"] as? Int
            if ownSession || (ownerPID.map { $0 != Int(getpid()) && processIsAlive(pid_t($0)) } ?? false) {
                if let image = owner?["image"] as? String { liveImages.insert(image) }
            } else {
                staleSessions.append(session)
            }
        }
        guard !staleSessions.isEmpty else { return }

        do {
            let info = try runPlist("/usr/bin/hdiutil", ["info", "-plist"])
            for device in staleImageDevices(inInfo: info, under: root, excluding: liveImages) {
                logger.notice("detaching stale guest disk \(device, privacy: .public)")
                detach(device)
            }
        } catch {
            logger.error("hdiutil info failed: \(error.localizedDescription, privacy: .public)")
        }
        for session in staleSessions {
            for volume in ["system", "data"] {
                let mountPoint = session.appendingPathComponent(volume, isDirectory: true)
                if isMountPoint(mountPoint) { unmount(mountPoint) }
            }
            removeSessionDirectory(session)
        }
    }

    // MARK: - Parsing

    /// The whole-disk device (`/dev/diskN`) among `hdiutil`'s system entities:
    /// the one holding the GUID partition scheme, else the lowest-numbered
    /// whole disk.
    static func wholeDisk(inEntities entities: Any?) -> String? {
        let entities = entities as? [[String: Any]] ?? []
        let wholeDisks = entities.compactMap { entity -> (device: String, number: Int, guid: Bool)? in
            guard let device = entity["dev-entry"] as? String,
                  let match = device.wholeMatch(of: /\/dev\/disk(\d+)/), let number = Int(match.1) else { return nil }
            return (device, number, entity["content-hint"] as? String == "GUID_partition_scheme")
        }
        return (wholeDisks.first(where: \.guid) ?? wholeDisks.min { $0.number < $1.number })?.device
    }

    /// Whether `diskutil info -plist` reports the volume mounted with ownership off.
    static func ownershipDisabled(inInfo info: [String: Any]) -> Bool {
        info["GlobalPermissionsEnabled"] as? Bool == false
    }

    /// The Data and System volume devices in `diskutil apfs list -plist` output.
    static func apfsVolumes(inList list: [String: Any]) -> (data: String?, system: String?) {
        let volumes = (list["Containers"] as? [[String: Any]] ?? []).flatMap { $0["Volumes"] as? [[String: Any]] ?? [] }
        func device(withRole role: String) -> String? {
            volumes.first { ($0["Roles"] as? [String])?.contains(role) == true }?["DeviceIdentifier"] as? String
        }
        return (device(withRole: "Data"), device(withRole: "System"))
    }

    /// Whole-disk devices of images attached from under `root`, skipping
    /// images a live session owns.
    static func staleImageDevices(inInfo info: [String: Any], under root: URL, excluding live: Set<String>) -> [String] {
        let prefix = root.resolvingSymlinksInPath().path + "/"
        return (info["images"] as? [[String: Any]] ?? []).compactMap { image in
            guard let path = (image["image-path"] as? String).map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }),
                  path.hasPrefix(prefix), !live.contains(path) else { return nil }
            return wholeDisk(inEntities: image["system-entities"])
        }
    }

    private static func apfsContainer(entities: Any?, wholeDisk: String) throws -> String {
        let partition = (entities as? [[String: Any]] ?? [])
            .first { ($0["content-hint"] as? String) == "Apple_APFS" }?["dev-entry"] as? String
            ?? "\(wholeDisk)s2"
        let info = try runPlist("/usr/sbin/diskutil", ["info", "-plist", partition])
        guard let container = info["APFSContainerReference"] as? String else {
            throw Failure(message: "No APFS container behind \(partition)")
        }
        return container
    }

    // MARK: - Tools

    /// Detaches an image by path, for an attach whose output named no whole disk.
    private static func detachImage(at imagePath: String) {
        guard let info = try? runPlist("/usr/bin/hdiutil", ["info", "-plist"]) else { return }
        for image in info["images"] as? [[String: Any]] ?? [] {
            guard let path = image["image-path"] as? String,
                  URL(fileURLWithPath: path).resolvingSymlinksInPath().path == imagePath else { continue }
            let devices = (image["system-entities"] as? [[String: Any]] ?? []).compactMap { $0["dev-entry"] as? String }
            if let device = wholeDisk(inEntities: image["system-entities"]) ?? devices.min() {
                detach(device)
            }
        }
    }

    private static func unmount(_ mountPoint: URL) {
        do {
            try run("/usr/sbin/diskutil", ["unmount", mountPoint.path], timeout: detachTimeout)
        } catch {
            _ = try? run("/usr/sbin/diskutil", ["unmount", "force", mountPoint.path], timeout: detachTimeout)
        }
    }

    /// `hdiutil detach`, retried while diskutil briefly holds the device, then forced.
    private static func detach(_ device: String) {
        for attempt in 0 ..< 3 {
            do {
                try run("/usr/bin/hdiutil", ["detach", device], timeout: detachTimeout)
                return
            } catch {
                logger.notice("detach \(device, privacy: .public) attempt \(attempt) failed: \(error.localizedDescription, privacy: .public)")
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        do {
            try run("/usr/bin/hdiutil", ["detach", "-force", device], timeout: detachTimeout)
        } catch {
            logger.error("forced detach of \(device, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Removes a session directory without ever recursing into a mounted
    /// volume: only empty mount points and the owner file are deleted.
    private static func removeSessionDirectory(_ session: URL) {
        defer { liveSessions.withLock { _ = $0.remove(session.lastPathComponent) } }
        for volume in ["data", "system"] { rmdir(session.appendingPathComponent(volume).path) }
        unlink(session.appendingPathComponent(ownerFileName).path)
        rmdir(session.path)
    }

    private static func isMountPoint(_ url: URL) -> Bool {
        var mount = stat()
        var parent = stat()
        guard stat(url.path, &mount) == 0, stat(url.deletingLastPathComponent().path, &parent) == 0 else { return false }
        return mount.st_dev != parent.st_dev
    }

    private static func processIsAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private static func runPlist(
        _ tool: String, _ arguments: [String], timeout: TimeInterval = detachTimeout
    ) throws -> [String: Any] {
        let output = try run(tool, arguments, timeout: timeout)
        guard let plist = try PropertyListSerialization.propertyList(from: output, options: [], format: nil)
            as? [String: Any] else {
            throw Failure(message: "\(tool) \(arguments.joined(separator: " ")) did not return a property list")
        }
        return plist
    }

    /// Runs a tool to completion and returns its stdout; throws with its
    /// stderr on failure, or after terminating it when it outlives `timeout`.
    @discardableResult
    private static func run(_ tool: String, _ arguments: [String], timeout: TimeInterval = detachTimeout) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        // Drain both pipes concurrently so a chatty tool can't fill one and wedge.
        let output = Output()
        let drained = DispatchGroup()
        for (pipe, keyPath) in [(stdout, \Output.stdout), (stderr, \Output.stderr)] {
            DispatchQueue.global(qos: .utility).async(group: drained) {
                output[keyPath: keyPath] = pipe.fileHandleForReading.readDataToEndOfFile()
            }
        }
        let command = "\((tool as NSString).lastPathComponent) \(arguments.joined(separator: " "))"
        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            if exited.wait(timeout: .now() + 5) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            throw Failure(message: "\(command) timed out after \(Int(timeout)) s")
        }
        _ = drained.wait(timeout: .now() + 5)

        guard process.terminationStatus == 0 else {
            let message = String(decoding: output.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message: "\(command) failed (\(process.terminationStatus)): \(message)")
        }
        return output.stdout
    }

    private final class Output: @unchecked Sendable {
        var stdout = Data()
        var stderr = Data()
    }
}
