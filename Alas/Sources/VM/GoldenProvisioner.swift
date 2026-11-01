import AlasCore
import Foundation
import os

/// A stopped guest disk mounted on the host for `VMGuestPatcher`.
protocol GoldenProvisioningDisk: Sendable {
    var dataVolume: URL { get }
    func systemVersion() throws -> (product: String, build: String)
    /// Unmounts and detaches. Blocking. False when the image may still be
    /// attached: the VM must then stay claimed.
    func close() -> Bool
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
        /// The run's task was cancelled; the golden is left as for a fallback.
        case cancelled
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
        static let helperOutdated = "the helper is out of date"
        static let shutdown = "macOS didn't shut down cleanly"
        static let vmStart = "the VM couldn't start"
        static let noAccount = "this VM doesn't have the alas account; install the helper from My Shared Files › helper in the VM"
        static let sshStillOn = "the helper is updated but SSH is still on; restart the VM"
        static let uidTaken = "this image already has a different user; finish it by hand"
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

    /// The steps this pipeline shares with `VMHelperUpdater`, keyed by build.
    var steps: GuestSetupSteps {
        GuestSetupSteps(
            boot: boot, stop: stop, openDisk: openDisk, closeDisk: closeDisk, disableSSHD: disableSSHD,
            guestIP: guestIP, ssh: ssh, helperHello: helperHello, sleep: sleep, now: now)
    }

    /// Cancelling the calling task stops the run at its next step, with the
    /// same cleanup as a fallback.
    func run(bundle: VMBundle, onStep: @MainActor (Step) -> Void) async -> Outcome {
        let build = bundle.url.lastPathComponent
        let steps = steps
        var patched = false
        do {
            try await materialiseAndPatch(bundle, build: build, steps: steps, onStep: onStep)
            patched = true

            try Self.enter(.finishing, onStep)
            try await steps.bootOrFail(build, reason: Reason.vmStart)
            try Task.checkCancellation()
            try await steps.finishOverSSH(bundle)

            try Self.enter(.verifying, onStep)
            try await steps.waitForHelperGrants(build)

            try Self.enter(.shuttingDown, onStep)
            await guestShutdown(build)
            guard await steps.waitUntil(timeout: Self.shutdownTimeout, interval: Self.shutdownInterval, { !isRunning(build) })
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
            // A step cut short by cancellation fails in its own way, if at all.
            let cancelled = Task.isCancelled
            let reason = cancelled ? "cancelled" : (error as? Failure)?.reason ?? Reason.vmStart
            Self.logger.error("Unattended setup of golden \(build, privacy: .public) stopped: \(reason, privacy: .public)")
            await stop(build)
            // A patch that failed part-way may already have turned sshd on.
            if patched || steps.sshdMayBeOn(bundle) { await steps.turnSSHDOffOffline(bundle) }
            return cancelled ? .cancelled : .fallback(reason: reason)
        }
    }

    /// Reports `step` unless the run was cancelled.
    private static func enter(_ step: Step, _ onStep: @MainActor (Step) -> Void) throws {
        try Task.checkCancellation()
        onStep(step)
    }

    /// First boot until the Data volume has a TCC database, then the offline
    /// patch. A slow first boot gets one longer retry.
    private func materialiseAndPatch(
        _ bundle: VMBundle, build: String, steps: GuestSetupSteps, onStep: @MainActor (Step) -> Void
    ) async throws {
        for wait in [Self.firstBootWait, Self.retryBootWait] {
            try Self.enter(.firstBoot, onStep)
            try await steps.bootOrFail(build, reason: Reason.firstStart)
            // A cancelled sleep returns at once, before the Data volume exists.
            await sleep(wait)
            await stop(build)

            try Self.enter(.patching, onStep)
            let result: Result<Void, Error>
            do {
                try await steps.withDisk(bundle) { disk in
                    try steps.markSSHDEnabled(bundle)
                    try await patch(disk)
                }
                result = .success(())
            } catch {
                result = .failure(error)
            }
            switch result {
            case .success:
                return
            case .failure(VMGuestPatcher.PatchError.missingTCCDatabase):
                Self.logger.notice("Golden \(build, privacy: .public) has no TCC database yet after \(wait, privacy: .public)")
                // Checked before the patch writes anything.
                steps.clearSSHDMarker(bundle)
                continue
            case .failure(VMGuestPatcher.PatchError.uidTaken):
                Self.logger.error("The golden disk already has another user at the alas account's uid")
                throw Failure(reason: Reason.uidTaken)
            case .failure(let error):
                Self.logger.error("Patching the golden disk failed: \(String(describing: error), privacy: .public)")
                throw Failure(reason: Reason.disk)
            }
        }
        throw Failure(reason: Reason.firstStart)
    }

    /// A start Virtualization refused, such as "Failed to lock auxiliary
    /// storage" while the previous VM on this bundle still holds it. Matched
    /// by domain, not by its localized text; `bootOrFail` retries these only
    /// within `storageLockTimeout`.
    static func isVirtualizationFailure(_ error: Error) -> Bool {
        (error as NSError).domain == "VZErrorDomain"
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

    /// Stops the running sshd too, which `launchctl disable` leaves loaded.
    /// `systemsetup` may be missing or need Full Disk Access.
    nonisolated static func sshdOffScript(account: VMGuestAccount) -> String {
        """
        \(sudo("/usr/sbin/systemsetup -f -setremotelogin off", account: account)) 2>/dev/null || true
        \(sudo("/bin/launchctl bootout system/com.openssh.sshd", account: account)) 2>/dev/null || true
        """
    }

    /// The command that restarts the guest from inside, run by the helper.
    nonisolated static func restartCommand(account: VMGuestAccount) -> String {
        sudo("/sbin/shutdown -r now", account: account)
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
        helperApp: URL? = GuestSetupSteps.embeddedHelperApp
    ) -> GoldenProvisioner {
        let account = VMGuestAccount.alas
        let steps = GuestSetupSteps.live(
            manager: manager,
            registryID: { WorktreeVMManager.goldenIDPrefix + $0 },
            boot: { build in
                // A golden the manual flow booted (with a display) is
                // replaced by a headless one.
                await manager.forceStopGolden(build: build)
                try GuestSetupSteps.requireRunning(try await manager.startGolden(build: build, keepingSSH: true))
            },
            stop: { build in await manager.forceStopGolden(build: build) })
        return GoldenProvisioner(
            boot: steps.boot,
            stop: steps.stop,
            openDisk: steps.openDisk,
            closeDisk: steps.closeDisk,
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
            disableSSHD: steps.disableSSHD,
            guestIP: steps.guestIP,
            ssh: steps.ssh,
            helperHello: steps.helperHello,
            guestShutdown: { build in
                manager.requestGuestCommand(
                    id: WorktreeVMManager.goldenIDPrefix + build, Self.shutdownCommand(account: account))
            },
            isRunning: { build in manager.isGoldenRunning(build: build) },
            seal: { bundle in try manager.sealGolden(bundle) },
            sleep: steps.sleep,
            now: steps.now)
    }
}

/// The guest steps the golden pipeline and `VMHelperUpdater` share: booting
/// past a storage lock the last VM still holds, attaching the stopped disk,
/// installing the helper over SSH from inside the guest, waiting for its
/// grants, and turning sshd off offline after a failure. `key` names the VM
/// to the boot, stop and hello seams (a golden's build, or a worktree id).
@MainActor
struct GuestSetupSteps {
    typealias Failure = GoldenProvisioner.Failure
    typealias Reason = GoldenProvisioner.Reason

    var boot: @MainActor (String) async throws -> Void
    /// Powers the VM off, forced.
    var stop: @MainActor (String) async -> Void
    /// Attaches the stopped VM's disk on the host. The VM must not boot, in
    /// any Alas process, until `closeDisk`.
    var openDisk: @MainActor (VMBundle) async throws -> any GoldenProvisioningDisk
    var closeDisk: @MainActor (any GoldenProvisioningDisk) async -> Void
    var disableSSHD: @MainActor (any GoldenProvisioningDisk) async throws -> Void
    var guestIP: @MainActor (VMBundle) async -> String?
    /// (host, script, timeout); the script goes on stdin.
    var ssh: @MainActor (String, String, Duration) async throws -> (exit: Int32, stdout: String)
    var helperHello: @MainActor (String) async throws -> VMGuestHello
    var sleep: @MainActor (Duration) async -> Void
    var now: @MainActor () -> ContinuousClock.Instant

    private static let logger = Logger(subsystem: "io.nlopez.alas", category: "guest-setup")

    func bootOrFail(_ key: String, reason: String) async throws {
        let deadline = now() + GoldenProvisioner.storageLockTimeout
        while true {
            do {
                try await boot(key)
                return
            } catch let failure as Failure {
                throw failure
            } catch where GoldenProvisioner.isVirtualizationFailure(error) && now() < deadline && !Task.isCancelled {
                Self.logger.notice("VM \(key, privacy: .public) failed to start (VZError \((error as NSError).code, privacy: .public)), its storage may still be locked; retrying the boot")
                await sleep(GoldenProvisioner.storageLockInterval)
            } catch {
                Self.logger.error("Booting VM \(key, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                throw Failure(reason: reason)
            }
        }
    }

    func withDisk(
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

    /// Records, before a patch turns the guest's sshd on, that it may be on
    /// (`WorktreeVMManager.sshdEnabledMarker`). Without it nothing is patched.
    func markSSHDEnabled(_ bundle: VMBundle) throws {
        do {
            try Data().write(to: WorktreeVMManager.sshdEnabledMarker(of: bundle))
        } catch {
            Self.logger.error("Writing the sshd marker of \(bundle.url.path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            throw Failure(reason: Reason.disk)
        }
    }

    /// Once sshd is off again, in the guest or offline.
    func clearSSHDMarker(_ bundle: VMBundle) {
        try? FileManager.default.removeItem(at: WorktreeVMManager.sshdEnabledMarker(of: bundle))
    }

    func sshdMayBeOn(_ bundle: VMBundle) -> Bool {
        FileManager.default.fileExists(atPath: WorktreeVMManager.sshdEnabledMarker(of: bundle).path)
    }

    /// The finishing script switches sshd off; a failure after the patch
    /// may not have reached it, which would leave sshd on with a known
    /// password. Logged, never thrown: the failure stands either way.
    func turnSSHDOffOffline(_ bundle: VMBundle) async {
        do {
            try await withDisk(bundle) { try await disableSSHD($0) }
            clearSSHDMarker(bundle)
        } catch {
            Self.logger.error("Turning sshd off on the guest disk failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Waits for the guest's lease and sshd, then installs the helper and its
    /// LaunchAgent from inside the guest and turns sshd off again. Returns
    /// the guest's address.
    @discardableResult
    func finishOverSSH(_ bundle: VMBundle) async throws -> String {
        var host: String?
        let reached = await waitUntil(timeout: GoldenProvisioner.reachTimeout, interval: GoldenProvisioner.reachInterval) {
            guard let ip = await guestIP(bundle) else { return false }
            guard let probe = try? await ssh(ip, "true", GoldenProvisioner.probeTimeout), probe.exit == 0 else { return false }
            host = ip
            return true
        }
        guard reached, let host else { throw Failure(reason: Reason.network) }

        let install: (exit: Int32, stdout: String)
        do {
            install = try await ssh(
                host, GoldenProvisioner.installHelperScript(account: .alas), GoldenProvisioner.installTimeout)
        } catch {
            Self.logger.error("Installing the helper over SSH failed: \(String(describing: error), privacy: .public)")
            throw Failure(reason: Reason.network)
        }
        guard install.exit == 0 else {
            Self.logger.error("Installing the helper exited \(install.exit, privacy: .public): \(install.stdout, privacy: .public)")
            throw Failure(reason: Reason.helper)
        }
        // The script ended by disabling sshd.
        clearSSHDMarker(bundle)
        // Belt and braces: the script only disabled sshd for future loads.
        // Either command may fail or drop this very connection.
        _ = try? await ssh(host, GoldenProvisioner.sshdOffScript(account: .alas), GoldenProvisioner.probeTimeout)
        return host
    }

    /// Waits until the helper answers with both grants and this build's
    /// protocol revision.
    func waitForHelperGrants(_ key: String) async throws {
        var lastHello: VMGuestHello?
        let ready = await waitUntil(timeout: GoldenProvisioner.helperTimeout, interval: GoldenProvisioner.helperInterval) {
            guard let hello = try? await helperHello(key) else { return false }
            lastHello = hello
            return hello.accessibility && hello.screenRecording && hello.protocolRevision == VMGuestProtocol.revision
        }
        guard ready else {
            guard let lastHello else { throw Failure(reason: Reason.helper) }
            Self.logger.error("The helper in \(key, privacy: .public) answered with revision \(lastHello.protocolRevision, privacy: .public), accessibility \(lastHello.accessibility, privacy: .public), screen recording \(lastHello.screenRecording, privacy: .public)")
            throw Failure(reason: lastHello.protocolRevision == VMGuestProtocol.revision ? Reason.helper : Reason.helperOutdated)
        }
    }

    /// Polls `condition` every `interval` until it holds or `timeout` has
    /// passed on the injected clock, attempts included. One attempt in flight
    /// at the deadline may finish past it.
    func waitUntil(
        timeout: Duration, interval: Duration, _ condition: @MainActor () async -> Bool
    ) async -> Bool {
        await Self.waitUntil(timeout: timeout, interval: interval, sleep: sleep, now: now, condition)
    }

    /// `waitUntil` on the given clock.
    static func waitUntil(
        timeout: Duration, interval: Duration,
        sleep: @MainActor (Duration) async -> Void, now: @MainActor () -> ContinuousClock.Instant,
        _ condition: @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = now() + timeout
        while true {
            // A cancelled sleep returns at once: without this it would spin.
            guard !Task.isCancelled else { return false }
            if await condition() { return true }
            let remaining = deadline - now()
            guard remaining > .zero else { return false }
            await sleep(min(interval, remaining))
        }
    }
}

// MARK: - Live seams

extension GuestSetupSteps {
    /// The guest helper bundle embedded in this app.
    static var embeddedHelperApp: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("alas-vm-guest/Alas VM Guest.app", isDirectory: true)
    }

    /// Fails unless the VM now runs here.
    static func requireRunning(_ outcome: VMStartOutcome) throws {
        switch outcome {
        case .running: return
        case .runningElsewhere(let label): throw Failure(reason: "macOS is running in \(label)")
        case .needsUserChoice: throw Failure(reason: "no VM slot was free")
        }
    }

    /// The steps wired to `manager`, the host's disk tools and `/usr/bin/ssh`.
    /// `registryID` maps a key, or the directory name of the bundle whose
    /// disk is opened, to the VM's registry id.
    static func live(
        manager: WorktreeVMManager,
        registryID: @escaping @MainActor (String) -> String,
        boot: @escaping @MainActor (String) async throws -> Void,
        stop: @escaping @MainActor (String) async -> Void
    ) -> GuestSetupSteps {
        let root = manager.root
        let account = VMGuestAccount.alas
        return GuestSetupSteps(
            boot: boot,
            stop: stop,
            openDisk: { bundle in
                let image = bundle.diskImage
                return try await openClaimed(id: registryID(bundle.url.lastPathComponent), manager: manager) {
                    try await Task.detached { try VMDiskSession.open(diskImage: image, root: root) }.value
                }
            },
            closeDisk: { disk in await closeClaimed(disk, manager: manager) },
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
            helperHello: { key in try await manager.helperStatus(id: registryID(key)) },
            sleep: { duration in try? await Task.sleep(for: duration) },
            now: { ContinuousClock.now })
    }
}

extension GuestSetupSteps {
    /// Claims VM `id` in the registry, so no Alas process boots it while its
    /// disk is attached here, then opens the disk. A failed open releases
    /// the claim, unless the image may still be attached.
    static func openClaimed(
        id: String, manager: WorktreeVMManager, open: @MainActor () async throws -> any GoldenProvisioningDisk
    ) async throws -> any GoldenProvisioningDisk {
        try manager.claimDisk(id: id)
        do {
            return try ClaimedDisk(disk: await open(), id: id)
        } catch let error as VMDiskSession.DetachFailed {
            logger.error("VM \(id, privacy: .public)'s disk stayed attached after a failed open; keeping its claim")
            throw error
        } catch {
            manager.releaseDisk(id: id)
            throw error
        }
    }

    /// Closes a disk `live` opened. The VM's claim is released only once its
    /// image is detached; one that may still be attached (and writable) stays
    /// claimed until a relaunch's dead-owner sweep.
    static func closeClaimed(_ disk: any GoldenProvisioningDisk, manager: WorktreeVMManager) async {
        let detached = await Task.detached { disk.close() }.value
        guard let claimed = disk as? ClaimedDisk else { return }
        guard detached else {
            logger.error("VM \(claimed.id, privacy: .public)'s disk stayed attached; keeping its claim")
            return
        }
        manager.releaseDisk(id: claimed.id)
    }
}

/// A VM disk attached under a registry claim, released on a detaching close.
struct ClaimedDisk: GoldenProvisioningDisk {
    let disk: any GoldenProvisioningDisk
    let id: String

    var dataVolume: URL { disk.dataVolume }
    func systemVersion() throws -> (product: String, build: String) { try disk.systemVersion() }
    func close() -> Bool { disk.close() }
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

    /// Whether `host` (an IPv4 address) accepts a TCP connection on `port`
    /// within `timeout`.
    static func portOpen(host: String, port: UInt16, timeout: Duration) async -> Bool {
        let milliseconds = Int32(timeout.components.seconds * 1000
            + timeout.components.attoseconds / 1_000_000_000_000_000)
        return await Task.detached { probe(host: host, port: port, timeoutMilliseconds: milliseconds) }.value
    }

    private static func probe(host: String, port: UInt16, timeoutMilliseconds: Int32) -> Bool {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var noSIGPIPE: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSIGPIPE, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connected == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&descriptor, 1, timeoutMilliseconds) == 1 else { return false }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { return false }
        return error == 0
    }

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
        let output = ProcessOutput()
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
            logger.notice("ssh \(host, privacy: .public) exited \(process.terminationStatus, privacy: .public): \(String(decoding: err, as: UTF8.self), privacy: .public)")
        }
        return (process.terminationStatus, String(decoding: out, as: UTF8.self))
    }
}

/// A child process's stdout and stderr, written by one reader each and read
/// once both finished or the drain gave up on them.
final class ProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    func set(_ data: Data, isStdout: Bool) {
        lock.withLock {
            if isStdout { stdout = data } else { stderr = data }
        }
    }

    func snapshot() -> (stdout: Data, stderr: Data) {
        lock.withLock { (stdout, stderr) }
    }
}
