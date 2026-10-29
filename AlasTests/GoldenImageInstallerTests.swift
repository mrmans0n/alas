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
        var helperReady = true
        var shutsDownCleanly = true
        /// Nil: sealed. Otherwise the reason in the failure note.
        let fallbackReason: String?

        var testDescription: String { name }
    }

    nonisolated static let pipelineCases: [PipelineCase] = [
        PipelineCase(name: "all good", fallbackReason: nil),
        PipelineCase(name: "TCC.db only after the longer retry boot", tccAfterBoots: 2, fallbackReason: nil),
        PipelineCase(name: "no TCC.db twice", tccAfterBoots: nil, fallbackReason: "macOS didn't finish its first start"),
        PipelineCase(name: "patch throws", patchFails: true, fallbackReason: "couldn't write the setup onto the disk"),
        PipelineCase(name: "guest never reachable over SSH", reachable: false,
                     fallbackReason: "couldn't reach the VM over the network"),
        PipelineCase(name: "helper never ready", helperReady: false, fallbackReason: "the helper didn't start"),
        PipelineCase(name: "guest shutdown not clean", shutsDownCleanly: false,
                     fallbackReason: "macOS didn't shut down cleanly"),
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
        // Every path leaves the golden stopped and the disk detached.
        #expect(!guest.running)
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
    private(set) var running = false
    private(set) var sealed = false
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

    func provisioner() -> GoldenProvisioner {
        GoldenProvisioner(
            boot: { [self] _ in
                boots += 1
                running = true
            },
            stop: { [self] _ in running = false },
            openDisk: { [disks] _ in
                disks.add(1)
                return Disk(disks: disks)
            },
            patch: { [self] _ in
                if c.patchFails { throw PatchFailed() }
                guard let after = c.tccAfterBoots, boots >= after else {
                    throw VMGuestPatcher.PatchError.missingTCCDatabase("TCC.db")
                }
            },
            guestIP: { [self] _ in c.reachable ? "192.168.64.3" : nil },
            ssh: { [self] _, _ in
                guard c.reachable else { throw Unreachable() }
                return (exit: 0, stdout: "")
            },
            helperHello: { [self] _ in
                VMGuestHello(guestVersion: "1", accessibility: c.helperReady, screenRecording: c.helperReady,
                             protocolRevision: 1)
            },
            guestShutdown: { [self] _ in
                if c.shutsDownCleanly { running = false }
            },
            isRunning: { [self] _ in running },
            seal: { [self] _ in sealed = true },
            sleep: { _ in })
    }
}
