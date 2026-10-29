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

    // MARK: - Unattended setup

    struct PipelineCase: CustomTestStringConvertible, Sendable {
        let name: String
        /// Boots after which the guest Data volume has a TCC database.
        var tccAfterBoots: Int? = 1
        var patchFails = false
        var reachable = true
        /// The helper's (accessibility, screen recording) grants.
        var grants = (true, true)
        var shutsDownCleanly = true
        /// Nil: sealed. Otherwise the reason in the failure note.
        let fallbackReason: String?
        /// A fallback after the patch turned sshd on must turn it off offline.
        var sshdTurnedOffOffline = false

        var testDescription: String { name }
    }

    nonisolated static let pipelineCases: [PipelineCase] = [
        PipelineCase(name: "all good", fallbackReason: nil),
        PipelineCase(name: "TCC.db only after the longer retry boot", tccAfterBoots: 2, fallbackReason: nil),
        PipelineCase(name: "no TCC.db twice", tccAfterBoots: nil, fallbackReason: "macOS didn't finish its first start"),
        PipelineCase(name: "patch throws", patchFails: true, fallbackReason: "couldn't write the setup onto the disk"),
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

    init(_ c: GoldenImageInstallerTests.PipelineCase) { self.c = c }

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

    func provisioner() -> GoldenProvisioner {
        GoldenProvisioner(
            boot: { [self] _ in
                stepDone()
                boots += 1
                running = true
            },
            stop: { [self] _ in
                stepDone()
                running = false
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
            ssh: { [self] _, _, timeout in
                guard c.reachable else {
                    advance(timeout)
                    throw Unreachable()
                }
                stepDone()
                return (exit: 0, stdout: "")
            },
            helperHello: { [self] _ in
                // A connect that finds no helper spends its retry window.
                advance(.seconds(10))
                return VMGuestHello(guestVersion: "1", accessibility: c.grants.0, screenRecording: c.grants.1,
                                    protocolRevision: 1)
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
