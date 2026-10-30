import AlasCore
import Foundation
import Testing
@testable import Alas

// Main actor: GoldenImageInstaller is main-actor-only.
@MainActor
@Suite("GoldenImageInstaller")
struct GoldenImageInstallerTests {
    @Test("an install running in another process is left untouched")
    func installLockHeldElsewhereTouchesNothing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoldenImageInstallerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let partial = root.appendingPathComponent("golden/25A1.partial", isDirectory: true)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        // A separate open file description conflicts like another process.
        let otherInstall = try ComputerUseDriverLock.acquire(
            at: root.appendingPathComponent("install.lock"), label: "Alas Dev")
        defer { otherInstall.release() }

        let installer = GoldenImageInstaller(root: root)
        await installer.start()

        #expect(installer.phase == .failed("macOS is being set up in another Alas."))
        #expect(FileManager.default.fileExists(atPath: partial.path))
    }

    @Test("a golden reopened by Customize is never set up unattended, and a stale failure doesn't hide it")
    func customizedGoldenIsLeftToTheUser() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoldenImageInstallerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let golden = VMBundle(url: root.appendingPathComponent("golden/25A1", isDirectory: true))
        try FileManager.default.createDirectory(at: golden.url, withIntermediateDirectories: true)
        let guest = FakeGuest(PipelineCase(name: "customized", fallbackReason: nil))
        let installer = GoldenImageInstaller(root: root, provisioner: guest.provisioner())
        // Another process holds the install lock: start fails before it resumes the golden.
        let otherInstall = try ComputerUseDriverLock.acquire(
            at: root.appendingPathComponent("install.lock"), label: "Alas Dev")
        await installer.start()
        otherInstall.release()
        #expect(installer.phase == .failed("macOS is being set up in another Alas."))
        installer.reloadFromDisk()
        #expect(installer.phase == .awaitingSetup(build: "25A1"))

        try Data().write(to: WorktreeVMManager.customizingMarker(of: golden))
        await installer.start()

        #expect(installer.phase == .awaitingSetup(build: "25A1"))
        #expect(guest.boots == 0)
        #expect(!guest.sealed)
    }

    // MARK: - Unattended setup

    struct PipelineCase: CustomTestStringConvertible, Sendable {
        let name: String
        /// Boots after which the guest Data volume has a TCC database.
        var tccAfterBoots: Int? = 1
        var patchFails = false
        var reachable = true
        /// The helper's (accessibility, screen recording) grants.
        var grants = (true, true)
        var helperRevision = VMGuestProtocol.revision
        var shutsDownCleanly = true
        /// Boots that fail first because the last VM still holds the storage lock.
        var lockedBoots = 0
        /// Nil: sealed. Otherwise the reason in the failure note.
        let fallbackReason: String?
        /// A fallback after the patch turned sshd on must turn it off offline.
        var sshdTurnedOffOffline = false
        /// Whether the VM to update has the `alas` account.
        var hasAccount = true
        /// Whether sshd still listens after the finishing script (until a
        /// restart, or for good).
        var sshAfterFinish: SSHAfterFinish = .off

        var testDescription: String { name }
    }

    enum SSHAfterFinish: Sendable { case off, untilRestart, evenAfterRestart }

    nonisolated static let pipelineCases: [PipelineCase] = [
        PipelineCase(name: "all good", fallbackReason: nil),
        PipelineCase(name: "TCC.db only after the longer retry boot", tccAfterBoots: 2, fallbackReason: nil),
        PipelineCase(name: "storage still locked right after install", lockedBoots: 3, fallbackReason: nil),
        PipelineCase(name: "no TCC.db twice", tccAfterBoots: nil, fallbackReason: "macOS didn't finish its first start"),
        PipelineCase(name: "patch throws", patchFails: true, fallbackReason: "couldn't write the setup onto the disk",
                     sshdTurnedOffOffline: true),
        PipelineCase(name: "guest never reachable over SSH", reachable: false,
                     fallbackReason: "couldn't reach the VM over the network", sshdTurnedOffOffline: true),
        PipelineCase(name: "helper without grants", grants: (false, false), fallbackReason: "the helper didn't start",
                     sshdTurnedOffOffline: true),
        PipelineCase(name: "helper with Accessibility only", grants: (true, false),
                     fallbackReason: "the helper didn't start", sshdTurnedOffOffline: true),
        PipelineCase(name: "helper with Screen Recording only", grants: (false, true),
                     fallbackReason: "the helper didn't start", sshdTurnedOffOffline: true),
        PipelineCase(name: "guest shutdown not clean", shutsDownCleanly: false,
                     fallbackReason: "macOS didn't shut down cleanly", sshdTurnedOffOffline: true),
    ]

    @Test("an installed golden resumes the unattended setup", arguments: pipelineCases)
    func unattendedSetupOutcome(_ c: PipelineCase) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoldenImageInstallerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("golden/25A1", isDirectory: true), withIntermediateDirectories: true)
        let guest = FakeGuest(c)
        let installer = GoldenImageInstaller(root: root, provisioner: guest.provisioner())
        #expect(installer.phase == .awaitingSetup(build: "25A1"))

        await installer.start()

        if let reason = c.fallbackReason {
            #expect(installer.phase == .awaitingSetup(build: "25A1"))
            #expect(installer.failureNote == "Automatic setup couldn't finish (\(reason)). Finish it by hand:")
            #expect(!guest.sealed)
        } else {
            #expect(installer.phase == .sealed(build: "25A1"))
            #expect(installer.failureNote == nil)
            #expect(guest.sealed)
        }
        #expect(guest.sshdTurnedOffOffline == c.sshdTurnedOffOffline)
        // Every path leaves the golden stopped and the disk detached, and no
        // wait runs far past its bound: one attempt at most.
        #expect(!guest.running)
        #expect(guest.openDisks == 0)
        #expect(guest.longestWait <= .seconds(240 + 15))
    }

    // MARK: - Helper update

    nonisolated static let helperUpdateCases: [PipelineCase] = [
        PipelineCase(name: "all good", fallbackReason: nil),
        PipelineCase(name: "guest never reachable over SSH", reachable: false,
                     fallbackReason: "couldn't reach the VM over the network", sshdTurnedOffOffline: true),
        PipelineCase(name: "helper without its grants", grants: (true, false), fallbackReason: "the helper didn't start",
                     sshdTurnedOffOffline: true),
        PipelineCase(name: "helper of another protocol revision", helperRevision: VMGuestProtocol.revision + 1,
                     fallbackReason: "the helper is out of date", sshdTurnedOffOffline: true),
        PipelineCase(name: "sshd still listening until the guest restarts", fallbackReason: nil,
                     sshAfterFinish: .untilRestart),
        PipelineCase(name: "sshd still listening after the restart", fallbackReason:
            "the helper is updated but SSH is still on; restart the VM", sshdTurnedOffOffline: true,
            sshAfterFinish: .evenAfterRestart),
        PipelineCase(name: "no alas account", fallbackReason:
            "this VM doesn't have the alas account; install the helper from My Shared Files › helper in the VM",
            hasAccount: false),
    ]

    @Test("a running VM's helper is reinstalled over SSH", arguments: helperUpdateCases)
    func helperUpdateOutcome(_ c: PipelineCase) async {
        let guest = FakeGuest(c)
        guest.alreadyBooted(running: true)

        let outcome = await guest.updater().run(
            id: "/repo/wt", bundle: VMBundle(url: URL(fileURLWithPath: "/nonexistent")))

        #expect(outcome == (c.fallbackReason.map { .failed(reason: $0) } ?? .updated))
        #expect(guest.sshdTurnedOffOffline == c.sshdTurnedOffOffline)
        // Without the account nothing is written: no grants, sshd untouched.
        #expect(guest.grantsPatched == c.hasAccount)
        #expect(!guest.sshListening)
        // Updated: running again with the new helper. Failed: stopped with sshd off.
        #expect(guest.running == (c.fallbackReason == nil))
        #expect(guest.openDisks == 0)
    }

    struct LeaseCase: CustomTestStringConvertible, Sendable {
        let name: String
        let mac: String
        let expected: String?
        var testDescription: String { name }
    }

    nonisolated static let leases = """
    {
    \tname=alas
    \tip_address=192.168.64.3
    \thw_address=1,a2:4:5e:0:1:2
    \tidentifier=1,a2:4:5e:0:1:2
    \tlease=0x6720f1b3
    }
    {
    \tname=alas
    \tip_address=192.168.64.9
    \thw_address=1,a2:4:5e:0:1:2
    \tidentifier=1,a2:4:5e:0:1:2
    \tlease=0x6720f2c0
    }
    {
    \tname=other
    \tip_address=192.168.64.5
    \thw_address=1,de:ad:be:ef:0:1
    \tlease=0x6720f9ff
    }
    """

    nonisolated static let leaseCases: [LeaseCase] = [
        LeaseCase(name: "leading zeros dropped, newest lease wins", mac: "a2:04:5e:00:01:02", expected: "192.168.64.9"),
        LeaseCase(name: "case-insensitive match", mac: "DE:AD:BE:EF:00:01", expected: "192.168.64.5"),
        LeaseCase(name: "no lease for the MAC", mac: "a2:04:5e:00:01:03", expected: nil),
    ]

    @Test("guest IP from the host's DHCP leases", arguments: leaseCases)
    func leasedIP(_ c: LeaseCase) {
        #expect(GoldenProvisioner.leasedIP(forMAC: c.mac, leases: Self.leases) == c.expected)
    }
}

/// A golden VM, its disk and its guest, simulated by the pipeline's seams.
@MainActor
private final class FakeGuest {
    private let c: GoldenImageInstallerTests.PipelineCase
    private(set) var boots = 0
    private var lockedBootsLeft: Int
    private(set) var running = false
    private(set) var sealed = false
    private(set) var sshdTurnedOffOffline = false
    /// The fake clock; sleeps and attempts advance it.
    private var clock = ContinuousClock.now
    private var waitStart: ContinuousClock.Instant?
    /// The longest stretch spent without a step finishing.
    private(set) var longestWait: Duration = .zero
    /// Disks opened and not closed yet; closed off the main actor.
    private let disks = OpenDisks()
    var openDisks: Int { disks.count }

    init(_ c: GoldenImageInstallerTests.PipelineCase) {
        self.c = c
        lockedBootsLeft = c.lockedBoots
    }

    private struct Unreachable: Error {}
    private struct PatchFailed: Error {}

    private final class OpenDisks: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func add(_ delta: Int) { lock.withLock { value += delta } }
    }

    private struct Disk: GoldenProvisioningDisk {
        let dataVolume = URL(fileURLWithPath: "/nonexistent")
        let disks: OpenDisks
        func systemVersion() throws -> (product: String, build: String) { ("27.2", "25A1") }
        func close() { disks.add(-1) }
    }

    /// Advances the clock, as a sleep or a slow attempt does, and tracks the
    /// longest run of consecutive waiting.
    private func advance(_ duration: Duration) {
        let start = waitStart ?? clock
        waitStart = start
        clock += duration
        longestWait = max(longestWait, clock - start)
    }

    private func stepDone() { waitStart = nil }

    private(set) var grantsPatched = false
    /// Whether the guest's port 22 answers.
    private(set) var sshListening = false

    /// The updater for this guest, already set up once.
    func updater() -> VMHelperUpdater {
        let provisioner = provisioner()
        return VMHelperUpdater(
            shutDown: { [self] id in await provisioner.stop(id) },
            hasAccount: { [self] _ in c.hasAccount },
            patchGrants: { [self] disk in
                grantsPatched = true
                try await provisioner.patch(disk)
            },
            sshPortOpen: { [self] _ in sshListening },
            restartGuest: { [self] _ in
                if c.sshAfterFinish == .untilRestart { sshListening = false }
            },
            steps: provisioner.steps)
    }

    /// A VM that already ran (its Data volume has a TCC database).
    func alreadyBooted(running: Bool) {
        boots = 1
        self.running = running
    }

    func provisioner() -> GoldenProvisioner {
        GoldenProvisioner(
            boot: { [self] _ in
                if lockedBootsLeft > 0 {
                    lockedBootsLeft -= 1
                    // Matched by domain: the localized text varies.
                    throw NSError(domain: "VZErrorDomain", code: 2)
                }
                stepDone()
                boots += 1
                running = true
            },
            stop: { [self] _ in
                stepDone()
                running = false
                sshListening = false
            },
            openDisk: { [disks] _ in
                disks.add(1)
                return Disk(disks: disks)
            },
            closeDisk: { disk in disk.close() },
            patch: { [self] _ in
                if c.patchFails { throw PatchFailed() }
                guard let after = c.tccAfterBoots, boots >= after else {
                    throw VMGuestPatcher.PatchError.missingTCCDatabase("TCC.db")
                }
            },
            disableSSHD: { [self] _ in sshdTurnedOffOffline = true },
            // Leased, but sshd may not answer.
            guestIP: { _ in "192.168.64.3" },
            ssh: { [self] _, script, timeout in
                guard c.reachable else {
                    advance(timeout)
                    throw Unreachable()
                }
                stepDone()
                if script != "true" { sshListening = c.sshAfterFinish != .off }
                return (exit: 0, stdout: "")
            },
            helperHello: { [self] _ in
                // A connect that finds no helper spends its retry window.
                advance(.seconds(10))
                return VMGuestHello(guestVersion: "1", accessibility: c.grants.0, screenRecording: c.grants.1,
                                    protocolRevision: c.helperRevision)
            },
            guestShutdown: { [self] _ in
                if c.shutsDownCleanly { running = false }
            },
            isRunning: { [self] _ in running },
            seal: { [self] _ in sealed = true },
            sleep: { [self] duration in advance(duration) },
            now: { [self] in clock })
    }
}
