import AlasCore
import Foundation
import os

/// A stopped guest disk mounted on the host for `VMGuestPatcher`.
protocol GoldenProvisioningDisk: Sendable {
    var dataVolume: URL { get }
    func systemVersion() throws -> (product: String, build: String)
    /// Unmounts and detaches. Blocking.
    func close()
}

extension VMDiskSession: GoldenProvisioningDisk {}

/// Sets up a freshly installed golden VM without the user: a first boot
/// materialises the Data volume, an offline patch adds the `alas` user,
/// auto-login, sshd and the helper's grants, a second (headless) boot
/// installs the helper over SSH and proves it has both grants, and the guest
/// then shuts itself down so `seal` finds clean-shutdown evidence.
///
/// Every step goes through an injected seam, so tests drive the pipeline
/// without VMs, disks or SSH. Waits are bounded by deadlines on the injected
/// clock, which counts the time each attempt takes as well as the sleeps.
@MainActor
struct GoldenProvisioner {
    enum Outcome: Equatable {
        case sealed
        /// The golden is left installed, unsealed and stopped; `reason` is a
        /// short phrase for "Automatic setup couldn't finish (<reason>)".
        case fallback(reason: String)
    }

    /// A failure whose reason the user should see instead of the step's.
    struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    enum Reason {
        static let firstStart = "macOS didn't finish its first start"
        static let disk = "couldn't write the setup onto the disk"
        static let network = "couldn't reach the VM over the network"
        static let helper = "the helper didn't start"
        static let shutdown = "macOS didn't shut down cleanly"
        static let vmStart = "the VM couldn't start"
    }

    typealias Step = GoldenImageInstaller.ProvisioningStep

    /// Boots the golden headless, taking a VM slot. Arguments are the build.
    var boot: @MainActor (String) async throws -> Void
    /// Powers the golden off, forced. Nothing booted by this pipeline is
    /// sealed unless the guest shut itself down.
    var stop: @MainActor (String) async -> Void
    /// Attaches the stopped golden's disk on the host. The golden must not
    /// boot, in any Alas process, until `closeDisk`.
    var openDisk: @MainActor (VMBundle) async throws -> any GoldenProvisioningDisk
    var closeDisk: @MainActor (any GoldenProvisioningDisk) async -> Void
    var patch: @MainActor (any GoldenProvisioningDisk) async throws -> Void
    /// Turns the guest's sshd off again offline, after a fallback that may
    /// have left the patched (sshd on, known password) guest behind.
    var disableSSHD: @MainActor (any GoldenProvisioningDisk) async throws -> Void
    /// The guest's address, if it has leased one yet.
    var guestIP: @MainActor (VMBundle) async -> String?
    /// Runs a shell script (sent on stdin) over SSH as the guest user:
    /// (host, script, timeout).
    var ssh: @MainActor (String, String, Duration) async throws -> (exit: Int32, stdout: String)
    var helperHello: @MainActor (String) async throws -> VMGuestHello
    /// Asks the guest to shut itself down. Does not wait.
    var guestShutdown: @MainActor (String) async -> Void
    var isRunning: @MainActor (String) -> Bool
    var seal: @MainActor (VMBundle) throws -> Void
    var sleep: @MainActor (Duration) async -> Void
    var now: @MainActor () -> ContinuousClock.Instant

    static let firstBootWait: Duration = .seconds(120)
    static let retryBootWait: Duration = .seconds(240)
    static let reachTimeout: Duration = .seconds(120)
    static let reachInterval: Duration = .seconds(5)
    static let probeTimeout: Duration = .seconds(15)
    static let installTimeout: Duration = .seconds(180)
    static let helperTimeout: Duration = .seconds(180)
    static let helperInterval: Duration = .seconds(3)
    static let shutdownTimeout: Duration = .seconds(120)
    static let shutdownInterval: Duration = .seconds(2)
    /// A VM that just stopped (or the installer's VM) releases its storage locks
    /// asynchronously, so a boot right after can fail to lock the auxiliary storage.
    static let storageLockTimeout: Duration = .seconds(30)
    static let storageLockInterval: Duration = .seconds(2)

    private static let logger = Logger(subsystem: "io.nlopez.alas", category: "golden-provisioner")

    func run(bundle: VMBundle, onStep: @MainActor (Step) -> Void) async -> Outcome {
        let build = bundle.url.lastPathComponent
        var patched = false
        do {
            try await materialiseAndPatch(bundle, build: build, onStep: onStep)
            patched = true

            onStep(.finishing)
            try await bootOrFail(build, reason: Reason.vmStart)
            try await finishOverSSH(bundle, build: build)

            onStep(.verifying)
            try await waitForHelperGrants(build)

            onStep(.shuttingDown)
            await guestShutdown(build)
            guard await waitUntil(timeout: Self.shutdownTimeout, interval: Self.shutdownInterval, { !isRunning(build) })
            else { throw Failure(reason: Reason.shutdown) }
            do {
                try seal(bundle)
            } catch {
                Self.logger.error("Sealing golden \(build, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                throw Failure(reason: Reason.shutdown)
            }
            Self.logger.info("Golden \(build, privacy: .public) set up unattended")
            return .sealed
        } catch {
            let reason = (error as? Failure)?.reason ?? Reason.vmStart
            Self.logger.error("Unattended setup of golden \(build, privacy: .public) stopped: \(reason, privacy: .public)")
            await stop(build)
            // A patch that failed part-way may already have turned sshd on.
            if patched || reason == Reason.disk { await turnSSHDOffOffline(bundle) }
            return .fallback(reason: reason)
        }
    }

    // MARK: - Steps

    /// First boot until the Data volume has a TCC database, then the offline
    /// patch. A slow first boot gets one longer retry.
    private func materialiseAndPatch(
        _ bundle: VMBundle, build: String, onStep: @MainActor (Step) -> Void
    ) async throws {
        for wait in [Self.firstBootWait, Self.retryBootWait] {
            onStep(.firstBoot)
            try await bootOrFail(build, reason: Reason.firstStart)
            await sleep(wait)
            await stop(build)

            onStep(.patching)
            let result: Result<Void, Error>
            do {
                try await withDisk(bundle) { try await patch($0) }
                result = .success(())
            } catch {
                result = .failure(error)
            }
            switch result {
            case .success:
                return
            case .failure(VMGuestPatcher.PatchError.missingTCCDatabase):
                Self.logger.notice("Golden \(build, privacy: .public) has no TCC database yet after \(wait, privacy: .public)")
                continue
            case .failure(let error):
                Self.logger.error("Patching the golden disk failed: \(String(describing: error), privacy: .public)")
                throw Failure(reason: Reason.disk)
            }
        }
        throw Failure(reason: Reason.firstStart)
    }

    private func withDisk(
        _ bundle: VMBundle, _ body: @MainActor (any GoldenProvisioningDisk) async throws -> Void
    ) async throws {
        let disk = try await openDisk(bundle)
        do {
            try await body(disk)
        } catch {
            await closeDisk(disk)
            throw error
        }
        await closeDisk(disk)
    }

    /// The finishing script switches sshd off; a fallback after the patch may
    /// not have reached it, so a sealed-by-hand image would keep sshd on with
    /// a known password. Logged, never thrown: the fallback stands either way.
    private func turnSSHDOffOffline(_ bundle: VMBundle) async {
        do {
            try await withDisk(bundle) { try await disableSSHD($0) }
        } catch {
            Self.logger.error("Turning sshd off on the golden disk failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func bootOrFail(_ build: String, reason: String) async throws {
        let deadline = now() + Self.storageLockTimeout
        while true {
            do {
                try await boot(build)
                return
            } catch let failure as Failure {
                throw failure
            } catch where Self.isStorageLockFailure(error) && now() < deadline {
                Self.logger.notice("Golden \(build, privacy: .public) storage still locked; retrying the boot")
                await sleep(Self.storageLockInterval)
            } catch {
                Self.logger.error("Booting golden \(build, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                throw Failure(reason: reason)
            }
        }
    }

    /// Virtualization's "Failed to lock auxiliary storage" (or the disk): the
    /// previous VM on this bundle hasn't let go of it yet.
    static func isStorageLockFailure(_ error: Error) -> Bool {
        let error = error as NSError
        guard error.domain == "VZErrorDomain" else { return false }
        return error.localizedDescription.localizedCaseInsensitiveContains("lock")
    }

    /// Waits for the guest's lease and sshd, then installs the helper and its
    /// LaunchAgent from inside the guest and turns sshd off again.
    private func finishOverSSH(_ bundle: VMBundle, build: String) async throws {
        var host: String?
        let reached = await waitUntil(timeout: Self.reachTimeout, interval: Self.reachInterval) {
            guard let ip = await guestIP(bundle) else { return false }
            guard let probe = try? await ssh(ip, "true", Self.probeTimeout), probe.exit == 0 else { return false }
            host = ip
            return true
        }
        guard reached, let host else { throw Failure(reason: Reason.network) }

        let install: (exit: Int32, stdout: String)
        do {
            install = try await ssh(host, Self.installHelperScript(account: .alas), Self.installTimeout)
        } catch {
            Self.logger.error("Installing the helper over SSH failed: \(String(describing: error), privacy: .public)")
            throw Failure(reason: Reason.network)
        }
        guard install.exit == 0 else {
            Self.logger.error("Installing the helper exited \(install.exit, privacy: .public): \(install.stdout, privacy: .public)")
            throw Failure(reason: Reason.helper)
        }
        // Belt and braces: it may be missing or need Full Disk Access, and
        // it may drop this very connection.
        _ = try? await ssh(
            host, Self.sudo("/usr/sbin/systemsetup -f -setremotelogin off", account: .alas), Self.probeTimeout)
    }

    private func waitForHelperGrants(_ build: String) async throws {
        var lastHello: VMGuestHello?
        let ready = await waitUntil(timeout: Self.helperTimeout, interval: Self.helperInterval) {
            guard let hello = try? await helperHello(build) else { return false }
            lastHello = hello
            return hello.accessibility && hello.screenRecording
        }
        guard ready else {
            if let lastHello {
                Self.logger.error("The golden helper answered without its grants: accessibility \(lastHello.accessibility, privacy: .public), screen recording \(lastHello.screenRecording, privacy: .public)")
            }
            throw Failure(reason: Reason.helper)
        }
    }

    /// Polls `condition` every `interval` until it holds or `timeout` has
    /// passed on the injected clock, attempts included. One attempt in flight
    /// at the deadline may finish past it.
    private func waitUntil(
        timeout: Duration, interval: Duration, _ condition: @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = now() + timeout
        while true {
            if await condition() { return true }
            let remaining = deadline - now()
            guard remaining > .zero else { return false }
            await sleep(min(interval, remaining))
        }
    }

    // MARK: - Guest commands

    nonisolated static let helperLabel = VMGuestProvisioning.helperBundleID
    nonisolated static let helperApp = "/Applications/Alas VM Guest.app"
    nonisolated static let sharedHelperApp = "/Volumes/My Shared Files/helper/Alas VM Guest.app"

    /// The command that shuts the guest down from inside, run by the helper.
    nonisolated static func shutdownCommand(account: VMGuestAccount) -> String {
        sudo("/sbin/shutdown -h now", account: account)
    }

    /// Copies the helper from the golden's `helper` share, writes its
    /// LaunchAgent as the guest user (a host-written one carries
    /// `com.apple.provenance` and launchd skips it), loads it into the GUI
    /// session (only root can over SSH), then disables sshd. Safe to run
    /// again: it unloads and replaces an earlier install.
    nonisolated static func installHelperScript(account: VMGuestAccount) -> String {
        let agent = "\(account.homeDirectory)/Library/LaunchAgents/\(helperLabel).plist"
        let plist = VMGuestProvisioning.launchAgentPlist(
            label: helperLabel, executable: "\(helperApp)/Contents/MacOS/Alas VM Guest")
        let xml = (try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let domain = "gui/\(account.uid)"
        return """
        set -e
        \(sudo("/bin/launchctl bootout \(domain)/\(helperLabel)", account: account)) 2>/dev/null || true
        \(sudo("/bin/rm -rf \(quote(helperApp))", account: account))
        \(sudo("/usr/bin/ditto \(quote(sharedHelperApp)) \(quote(helperApp))", account: account))
        \(sudo("/usr/bin/xattr -dr com.apple.quarantine \(quote(helperApp))", account: account)) 2>/dev/null || true
        /bin/mkdir -p \(quote((agent as NSString).deletingLastPathComponent))
        /bin/cat > \(quote(agent)) <<'ALAS_PLIST'
        \(xml.trimmingCharacters(in: .newlines))
        ALAS_PLIST
        n=0
        until \(sudo("/bin/launchctl bootstrap \(domain) \(quote(agent))", account: account)); do
          n=$((n + 1)); [ $n -ge 5 ] && exit 1; sleep 1
        done
        \(sudo("/bin/launchctl disable system/com.openssh.sshd", account: account))
        """
    }

    /// `command` as root, with the password fed to `sudo -S` (its prompt
    /// goes to stderr; `-p ''` keeps it empty).
    nonisolated static func sudo(_ command: String, account: VMGuestAccount) -> String {
        "echo \(quote(account.password)) | /usr/bin/sudo -S -p '' \(command)"
    }

    nonisolated static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - DHCP leases

    /// The address the host's DHCP server (`/var/db/dhcpd_leases`) last
    /// leased to `mac`. The lease file drops leading zeros in octets, so
    /// addresses compare by value; the newest `lease=0x…` wins.
    nonisolated static func leasedIP(forMAC mac: String, leases: String) -> String? {
        guard let wanted = octets(mac) else { return nil }
        var best: (ip: String, lease: UInt64)?
        for block in leases.components(separatedBy: "}") {
            var fields: [String: String] = [:]
            for line in block.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "{"))
                guard let equals = trimmed.firstIndex(of: "=") else { continue }
                fields[String(trimmed[..<equals])] = String(trimmed[trimmed.index(after: equals)...])
            }
            guard let ip = fields["ip_address"], let hardware = fields["hw_address"] else { continue }
            let address = hardware.split(separator: ",", maxSplits: 1).last.map(String.init) ?? hardware
            guard octets(address) == wanted else { continue }
            let lease = fields["lease"].flatMap { UInt64($0.replacingOccurrences(of: "0x", with: ""), radix: 16) } ?? 0
            if best == nil || lease >= best!.lease { best = (ip, lease) }
        }
        return best?.ip
    }

    private nonisolated static func octets(_ mac: String) -> [UInt8]? {
        let parts = mac.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        guard parts.count == 6 else { return nil }
        let values = parts.compactMap { UInt8($0, radix: 16) }
        return values.count == 6 ? values : nil
    }
}

// MARK: - Live seams

extension GoldenProvisioner {
    /// The pipeline wired to `manager`'s golden VM, the host's disk tools and
    /// `/usr/bin/ssh`. `helperApp` is the helper bundle embedded in this app,
    /// whose code requirement the offline grants name.
    static func live(
        manager: WorktreeVMManager,
        helperApp: URL? = Bundle.main.resourceURL?
            .appendingPathComponent("alas-vm-guest/Alas VM Guest.app", isDirectory: true)
    ) -> GoldenProvisioner {
        let root = manager.root
        let account = VMGuestAccount.alas
        return GoldenProvisioner(
            boot: { build in
                // A golden the manual flow booted (with a display) is
                // replaced by a headless one.
                await manager.forceStopGolden(build: build)
                switch try await manager.startGolden(build: build) {
                case .running: return
                case .runningElsewhere(let label): throw Failure(reason: "macOS is running in \(label)")
                case .needsUserChoice: throw Failure(reason: "no VM slot was free")
                }
            },
            stop: { build in await manager.forceStopGolden(build: build) },
            openDisk: { bundle in
                // Claimed in the registry first, so no Alas process boots
                // the golden while its disk is attached here.
                let build = bundle.url.lastPathComponent
                try manager.claimGoldenDisk(build: build)
                let image = bundle.diskImage
                do {
                    let session = try await Task.detached { try VMDiskSession.open(diskImage: image, root: root) }.value
                    return ClaimedGoldenDisk(session: session, build: build)
                } catch {
                    manager.releaseGoldenDisk(build: build)
                    throw error
                }
            },
            closeDisk: { disk in
                await Task.detached { disk.close() }.value
                if let claimed = disk as? ClaimedGoldenDisk { manager.releaseGoldenDisk(build: claimed.build) }
            },
            patch: { disk in
                guard let helperApp else { throw Failure(reason: Reason.disk) }
                try await Task.detached {
                    try VMGuestPatcher.patch(
                        dataVolume: disk.dataVolume,
                        systemVersion: disk.systemVersion(),
                        helperCodeRequirement: HelperCodeRequirement.designatedRequirementData(of: helperApp),
                        account: account)
                }.value
            },
            disableSSHD: { disk in
                try await Task.detached { try VMGuestPatcher.disableSSH(dataVolume: disk.dataVolume) }.value
            },
            guestIP: { bundle in
                let macFile = bundle.macAddress
                return await Task.detached {
                    guard let mac = try? String(contentsOf: macFile, encoding: .utf8),
                          let leases = try? String(contentsOfFile: "/var/db/dhcpd_leases", encoding: .utf8)
                    else { return nil }
                    return GoldenProvisioner.leasedIP(forMAC: mac, leases: leases)
                }.value
            },
            ssh: { host, script, timeout in
                try await GuestSSH.run(host: host, account: account, script: script, timeout: timeout)
            },
            helperHello: { build in try await manager.goldenHelperStatus(build: build) },
            guestShutdown: { build in
                manager.requestGoldenGuestCommand(build: build, Self.shutdownCommand(account: account))
            },
            isRunning: { build in manager.isGoldenRunning(build: build) },
            seal: { bundle in try manager.sealGolden(bundle) },
            sleep: { duration in try? await Task.sleep(for: duration) },
            now: { ContinuousClock.now })
    }
}

/// A golden disk attached under a registry claim, released on close.
private struct ClaimedGoldenDisk: GoldenProvisioningDisk {
    let session: VMDiskSession
    let build: String

    var dataVolume: URL { session.dataVolume }
    func systemVersion() throws -> (product: String, build: String) { try session.systemVersion() }
    func close() { session.close() }
}

/// `/usr/bin/ssh` with password authentication answered by a throwaway
/// `SSH_ASKPASS` script. The user's ssh config, agent and keys are ignored,
/// and host keys are never persisted: every golden VM is a new, short-lived
/// host. The script goes on stdin, so the password `sudo -S` reads never
/// shows in the host's process list.
enum GuestSSH {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// How long the output may keep draining after ssh exits, for a child
    /// that inherited the pipes and lingers.
    private static let drainGrace: TimeInterval = 5

    static func run(
        host: String, account: VMGuestAccount, script: String, timeout: Duration
    ) async throws -> (exit: Int32, stdout: String) {
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        return try await Task.detached {
            try runBlocking(host: host, account: account, script: script, timeout: seconds)
        }.value
    }

    private static let logger = Logger(subsystem: "io.nlopez.alas", category: "guest-ssh")

    static func arguments(host: String, account: VMGuestAccount) -> [String] {
        [
            "-F", "/dev/null",
            "-T",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "PubkeyAuthentication=no",
            "-o", "PreferredAuthentications=password,keyboard-interactive",
            "-o", "NumberOfPasswordPrompts=1",
            "-o", "ConnectTimeout=8",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "BatchMode=no",
            "-o", "IdentitiesOnly=yes",
            "-o", "IdentityAgent=none",
            "-o", "LogLevel=ERROR",
            "\(account.shortName)@\(host)",
            "/bin/zsh -s",
        ]
    }

    private static func runBlocking(
        host: String, account: VMGuestAccount, script: String, timeout: TimeInterval
    ) throws -> (exit: Int32, stdout: String) {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("alas-askpass-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: directory) }
        let askpass = directory.appendingPathComponent("askpass")
        let askpassScript = "#!/bin/sh\nprintf '%s\\n' \(GoldenProvisioner.quote(account.password))\n"
        guard fm.createFile(atPath: askpass.path, contents: Data(askpassScript.utf8), attributes: [.posixPermissions: 0o700]) else {
            throw Failure(message: "Could not write \(askpass.path)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments(host: host, account: account)
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS"] = askpass.path
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["DISPLAY"] = environment["DISPLAY"] ?? ":0"
        environment.removeValue(forKey: "SSH_AUTH_SOCK")
        process.environment = environment
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        // The app doesn't ignore SIGPIPE: if ssh exits first, the write must fail rather than kill Alas.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()

        // The pipe buffer holds the whole script; closing ends the remote shell's input.
        DispatchQueue.global().async {
            try? stdin.fileHandleForWriting.write(contentsOf: Data(script.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        // Both pipes drain concurrently so neither can fill and stall ssh.
        let group = DispatchGroup()
        let output = Output()
        for (pipe, isStdout) in [(stdout, true), (stderr, false)] {
            group.enter()
            DispatchQueue.global().async {
                output.set(pipe.fileHandleForReading.readDataToEndOfFile(), isStdout: isStdout)
                group.leave()
            }
        }
        let killer = DispatchWorkItem { [process] in if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        process.waitUntilExit()
        killer.cancel()
        if group.wait(timeout: .now() + drainGrace) == .timedOut {
            logger.notice("ssh \(host, privacy: .public) exited but its output stayed open; not waiting for it")
        }

        let (out, err) = output.snapshot()
        if process.terminationStatus != 0 {
            logger.notice("ssh \(host, privacy: .public) exited \(process.terminationStatus, privacy: .public): \(err, privacy: .public)")
        }
        return (process.terminationStatus, out)
    }

    /// Written by one reader each; read once both finished or the drain gave up.
    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var stdout = Data()
        private var stderr = Data()

        func set(_ data: Data, isStdout: Bool) {
            lock.withLock {
                if isStdout { stdout = data } else { stderr = data }
            }
        }

        func snapshot() -> (stdout: String, stderr: String) {
            lock.withLock { (String(decoding: stdout, as: UTF8.self), String(decoding: stderr, as: UTF8.self)) }
        }
    }
}
