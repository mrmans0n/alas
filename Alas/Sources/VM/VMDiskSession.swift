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

    /// The image may still be attached, after `close()` or a failed `open`
    /// whose cleanup could not detach it. Its session directory stays for
    /// the next sweep, and its VM must stay claimed.
    struct DetachFailed: LocalizedError {
        /// Why `open` gave up, when it did.
        var underlying: String?
        var errorDescription: String? {
            "The VM disk could not be detached" + (underlying.map { " after: \($0)" } ?? "")
        }
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

    deinit { _ = close() }

    static func open(diskImage: URL, root: URL = Paths.vmsRoot) throws -> VMDiskSession {
        let fm = FileManager.default
        let name = UUID().uuidString
        liveSessions.withLock { _ = $0.insert(name) }
        let session = root.appendingPathComponent("mnt/\(name)", isDirectory: true)
        let dataMount = session.appendingPathComponent("data", isDirectory: true)
        let systemMount = session.appendingPathComponent("system", isDirectory: true)
        let imagePath = diskImage.resolvingSymlinksInPath().path

        let attached: [String: Any]
        var attemptedAttach = false
        do {
            // The owner file comes first: a sweep that sees the directory can always tell who owns it.
            try fm.createDirectory(at: session, withIntermediateDirectories: true)
            let owner: [String: Any] = ["pid": Int(getpid()), "image": imagePath]
            try PropertyListSerialization.data(fromPropertyList: owner, format: .xml, options: 0)
                .write(to: session.appendingPathComponent(ownerFileName))
            try fm.createDirectory(at: dataMount, withIntermediateDirectories: false)
            try fm.createDirectory(at: systemMount, withIntermediateDirectories: false)
            // Someone else (another Alas process, or a hand attach) holds it: leave theirs alone.
            if isImageAttached(imagePath) {
                throw Failure(message: "The VM disk is already attached elsewhere: \(imagePath)")
            }
            attemptedAttach = true
            attached = try runPlist(
                "/usr/bin/hdiutil", ["attach", "-readwrite", "-nomount", "-plist", diskImage.path], timeout: attachTimeout
            )
        } catch {
            // A killed or failed attach may still have attached the image; never leave our attach behind.
            throw abandon(session, detached: !attemptedAttach || detachImage(at: imagePath), error)
        }
        guard let wholeDisk = Self.wholeDisk(inEntities: attached["system-entities"]) else {
            throw abandon(session, detached: detachImage(at: imagePath), Failure(
                message: "hdiutil attached \(diskImage.lastPathComponent) but reported no whole disk"))
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
            throw abandon(session, detached: detach(wholeDisk), error)
        }
        return VMDiskSession(
            dataVolume: dataMount, systemVolume: systemMounted ? systemMount : nil,
            wholeDisk: wholeDisk, sessionDirectory: session
        )
    }

    /// The error a failed `open` throws. Once the image is detached the
    /// session directory goes; otherwise it stays, owner file included, so
    /// the next launch's sweep retries the detach.
    private static func abandon(_ session: URL, detached: Bool, _ error: Error) -> Error {
        guard detached else {
            logger.error("Could not detach after a failed open: \(error.localizedDescription, privacy: .public)")
            return DetachFailed(underlying: error.localizedDescription)
        }
        removeSessionDirectory(session)
        return error
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

    /// Unmounts both volumes and detaches the image. Safe to call again:
    /// when the detach failed it returns false and keeps the session
    /// directory, so a later close or the next launch's sweep retries it.
    func close() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return true }
        if let systemVolume { Self.unmount(systemVolume) }
        Self.unmount(dataVolume)
        guard Self.detach(wholeDisk) else { return false }
        closed = true
        Self.removeSessionDirectory(sessionDirectory)
        return true
    }

    // MARK: - Stale sessions

    /// Detaches the images and removes the mount directories that an Alas
    /// process left when it died mid-session, as named by their owner
    /// records (see `staleSessionsToRemove`). Sessions whose owner is still
    /// running are left alone. Blocking: call off the main actor.
    static func detachStaleSessions(under root: URL) {
        let mnt = root.appendingPathComponent("mnt", isDirectory: true)
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: mnt, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )) ?? []
        // A launch that never opened a session doesn't shell out.
        guard !directories.isEmpty else { return }
        func record(_ directory: URL) -> SessionRecord {
            let owner = (try? Data(contentsOf: directory.appendingPathComponent(ownerFileName)))
                .flatMap { try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) }
                as? [String: Any]
            return SessionRecord(
                name: directory.lastPathComponent, pid: owner?["pid"] as? Int, image: owner?["image"] as? String)
        }
        // Read from disk on every call, so the check right before a detach
        // sees a session that came alive since the sweep started.
        func isLive(_ session: SessionRecord) -> Bool {
            if liveSessions.withLock({ $0.contains(session.name) }) { return true }
            let current = record(mnt.appendingPathComponent(session.name, isDirectory: true))
            return current.pid.map { $0 != Int(getpid()) && processIsAlive(pid_t($0)) } ?? false
        }
        let sessions = directories.map(record)
        guard sessions.contains(where: { !isLive($0) }) else { return }

        let info: [String: Any]
        do {
            info = try runPlist("/usr/bin/hdiutil", ["info", "-plist"])
        } catch {
            // Its images may still be attached: keep the directories so the
            // next sweep tries again.
            logger.error("hdiutil info failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        let removable = staleSessionsToRemove(info: info, sessions: sessions, isLive: isLive) { device in
            logger.notice("detaching stale guest disk \(device, privacy: .public)")
            return detach(device)
        }
        for name in removable {
            let session = mnt.appendingPathComponent(name, isDirectory: true)
            for volume in ["system", "data"] {
                let mountPoint = session.appendingPathComponent(volume, isDirectory: true)
                if isMountPoint(mountPoint) { unmount(mountPoint) }
            }
            removeSessionDirectory(session)
        }
    }

    /// A session directory's `owner.plist`: the process that opened it and
    /// the image it attached. Both nil when the file is missing or unreadable.
    struct SessionRecord: Equatable {
        let name: String
        let pid: Int?
        let image: String?
    }

    /// Detaches the images of stale sessions and returns the stale session
    /// directories that may go. Only an image a stale owner record names is
    /// ever detached: never one a live session also names, nor anything
    /// else attached from under the VM root. `isLive` is asked again right
    /// before each detach. A session stays when its record names no image
    /// (it may be one being created) or when its image may still be
    /// attached, so the next sweep retries it.
    static func staleSessionsToRemove(
        info: [String: Any], sessions: [SessionRecord],
        isLive: (SessionRecord) -> Bool, detach: (String) -> Bool
    ) -> [String] {
        func resolved(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        let liveImages = Set(sessions.filter(isLive).compactMap { $0.image.map(resolved) })
        var attached: [String: [String]] = [:]
        for image in info["images"] as? [[String: Any]] ?? [] {
            guard let path = image["image-path"] as? String, let device = wholeDisk(inEntities: image["system-entities"])
            else { continue }
            attached[resolved(path), default: []].append(device)
        }
        var detachedImages = Set<String>()
        var removable: [String] = []
        for session in sessions where !isLive(session) {
            guard let image = session.image.map(resolved) else { continue }
            let devices = attached[image] ?? []
            if devices.isEmpty || liveImages.contains(image) || detachedImages.contains(image) {
                // Not attached, or attached for a live session, which keeps it.
                removable.append(session.name)
                continue
            }
            guard !isLive(session) else { continue }
            guard devices.allSatisfy(detach) else { continue }
            detachedImages.insert(image)
            removable.append(session.name)
        }
        return removable
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

    /// Whether `hdiutil` lists the image as attached. An unreadable `hdiutil info` counts as attached.
    private static func isImageAttached(_ imagePath: String) -> Bool {
        guard let info = try? runPlist("/usr/bin/hdiutil", ["info", "-plist"]) else { return true }
        return (info["images"] as? [[String: Any]] ?? []).contains { image in
            (image["image-path"] as? String).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == imagePath
        }
    }

    /// Detaches an image by path, for an attach whose output named no whole disk.
    /// False when it may still be attached: `hdiutil info` failed, or a detach did.
    private static func detachImage(at imagePath: String) -> Bool {
        guard let info = try? runPlist("/usr/bin/hdiutil", ["info", "-plist"]) else { return false }
        var detached = true
        for image in info["images"] as? [[String: Any]] ?? [] {
            guard let path = image["image-path"] as? String,
                  URL(fileURLWithPath: path).resolvingSymlinksInPath().path == imagePath else { continue }
            let devices = (image["system-entities"] as? [[String: Any]] ?? []).compactMap { $0["dev-entry"] as? String }
            if let device = wholeDisk(inEntities: image["system-entities"]) ?? devices.min(), !detach(device) {
                detached = false
            }
        }
        return detached
    }

    private static func unmount(_ mountPoint: URL) {
        do {
            try run("/usr/sbin/diskutil", ["unmount", mountPoint.path], timeout: detachTimeout)
        } catch {
            _ = try? run("/usr/sbin/diskutil", ["unmount", "force", mountPoint.path], timeout: detachTimeout)
        }
    }

    /// `hdiutil detach`, retried while diskutil briefly holds the device, then
    /// forced. False when even the forced detach failed.
    @discardableResult
    private static func detach(_ device: String) -> Bool {
        for attempt in 0 ..< 3 {
            do {
                try run("/usr/bin/hdiutil", ["detach", device], timeout: detachTimeout)
                return true
            } catch {
                logger.notice("detach \(device, privacy: .public) attempt \(attempt) failed: \(error.localizedDescription, privacy: .public)")
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        do {
            try run("/usr/bin/hdiutil", ["detach", "-force", device], timeout: detachTimeout)
            return true
        } catch {
            logger.error("forced detach of \(device, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return false
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
        let output = ProcessOutput()
        let drained = DispatchGroup()
        for (pipe, isStdout) in [(stdout, true), (stderr, false)] {
            DispatchQueue.global(qos: .utility).async(group: drained) {
                output.set(pipe.fileHandleForReading.readDataToEndOfFile(), isStdout: isStdout)
            }
        }
        let command = "\((tool as NSString).lastPathComponent) \(arguments.joined(separator: " "))"
        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            if exited.wait(timeout: .now() + 5) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            throw Failure(message: "\(command) timed out after \(Int(timeout)) s")
        }
        _ = drained.wait(timeout: .now() + 5)
        // A reader still running after the wait gave up writes under the lock.
        let (out, err) = output.snapshot()

        guard process.terminationStatus == 0 else {
            let message = String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message: "\(command) failed (\(process.terminationStatus)): \(message)")
        }
        return out
    }
}
