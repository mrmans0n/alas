import AlasCore
import Foundation
import Testing
@testable import Alas

// Main actor: LinuxGoldenInstaller is main-actor-only.
@MainActor
@Suite("LinuxGoldenInstaller")
struct LinuxGoldenInstallerTests {
    enum Expected: Equatable, Sendable {
        case sealed
        case failed(String)
        case idle
    }

    struct PipelineCase: CustomTestStringConvertible, Sendable {
        let name: String
        var checksumMatches = true
        var powersOffAfterSetup = true
        var helperAnswers = true
        var cancelDuringConvert = false
        /// Boots that fail first because the last VM still holds the storage lock.
        var lockedBoots = 0
        let expected: Expected

        var testDescription: String { name }
    }

    nonisolated static let pipelineCases: [PipelineCase] = [
        PipelineCase(name: "all good", expected: .sealed),
        PipelineCase(name: "storage still locked right after the first start", lockedBoots: 3, expected: .sealed),
        PipelineCase(name: "checksum mismatch", checksumMatches: false,
                     expected: .failed(LinuxGoldenInstaller.Reason.checksum)),
        PipelineCase(name: "never powers off after setup", powersOffAfterSetup: false,
                     expected: .failed(LinuxGoldenInstaller.Reason.firstStart)),
        PipelineCase(name: "helper never answers", helperAnswers: false,
                     expected: .failed(LinuxGoldenInstaller.Reason.helper)),
        PipelineCase(name: "cancelled while converting", cancelDuringConvert: true, expected: .idle),
    ]

    @Test("the unattended pipeline ends sealed, failed or cancelled", arguments: pipelineCases)
    func pipelineOutcome(_ c: PipelineCase) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LinuxGoldenInstallerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let guest = FakeLinuxGuest(c)
        let imageRoot = root.appendingPathComponent("linux-images", isDirectory: true)
        try FileManager.default.createDirectory(at: imageRoot, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: imageRoot.appendingPathComponent("20250101.img.partial"))
        let installer = LinuxGoldenInstaller(root: root, steps: guest.steps())
        guest.cancel = { [weak installer] in installer?.cancel() }

        await installer.start()

        let serial = LinuxGoldenImage.serial
        let golden = LinuxVMBundle(url: root.appendingPathComponent("golden-linux/\(serial)", isDirectory: true))
        switch c.expected {
        case .sealed:
            #expect(installer.phase == .sealed(serial: serial))
            #expect(guest.sealed)
            #expect(golden.isSealed)
            #expect(LinuxGoldenInstaller.availableGolden(root: root)?.url.lastPathComponent == serial)
            // The first boot ran with the seed, the check without it.
            #expect(guest.bootSeeds == [true, false])
        case .failed(let reason):
            #expect(installer.phase == .failed(reason))
            #expect(!guest.sealed)
            #expect(!FileManager.default.fileExists(atPath: golden.url.path))
        case .idle:
            #expect(installer.phase == .idle)
            #expect(!guest.sealed)
            #expect(!FileManager.default.fileExists(atPath: golden.url.path))
        }
        // A sealed golden drops every downloaded image, of any serial. A damaged
        // download is dropped; any other failure keeps it for the next Set up.
        let images = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("linux-images").path)) ?? []
        #expect(images.isEmpty == (c.expected == .sealed))
        #expect(FileManager.default.fileExists(atPath: guest.downloaded?.path ?? "/")
            == (c.checksumMatches && c.expected != .sealed))
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("golden-linux/\(serial).partial").path))
        #expect(!guest.running)
    }
}

/// The download, disk tools and a Linux guest, simulated by the pipeline's seams.
@MainActor
private final class FakeLinuxGuest {
    private let c: LinuxGoldenInstallerTests.PipelineCase
    private(set) var running = false
    private(set) var sealed = false
    private(set) var bootSeeds: [Bool] = []
    private(set) var downloaded: URL?
    /// What Cancel does, called while converting.
    var cancel: (() -> Void)?
    /// The fake clock; sleeps and attempts advance it.
    private var clock = ContinuousClock.now

    private var lockedBootsLeft: Int

    init(_ c: LinuxGoldenInstallerTests.PipelineCase) {
        self.c = c
        lockedBootsLeft = c.lockedBoots
    }

    private struct NotRunning: Error {}

    func steps() -> LinuxGoldenInstaller.Steps {
        LinuxGoldenInstaller.Steps(
            download: { [self] destination, progress in
                try Data("qcow2".utf8).write(to: destination)
                downloaded = destination
                progress(1)
            },
            verify: { [self] _, _ in c.checksumMatches },
            convert: { [self] _, destination, _, progress in
                try Data().write(to: destination)
                progress(0.5)
                if c.cancelDuringConvert {
                    cancel?()
                    try Task.checkCancellation()
                }
            },
            writeIdentity: { bundle in try Data("id".utf8).write(to: bundle.machineIdentifier) },
            makeSeedISO: { iso in try Data("iso".utf8).write(to: iso) },
            boot: { [self] _, seed in
                // The check's boot finds the first start's storage still locked.
                if seed == nil, lockedBootsLeft > 0 {
                    lockedBootsLeft -= 1
                    throw NSError(domain: "VZErrorDomain", code: 2)
                }
                bootSeeds.append(seed != nil)
                running = true
            },
            waitForSelfPoweroff: { [self] timeout in
                // Setup powers the seeded boot off; the check's boot stops when asked.
                let powersOff = bootSeeds.last == true ? c.powersOffAfterSetup : true
                guard powersOff else {
                    clock += timeout
                    return false
                }
                running = false
                return true
            },
            helperHello: { [self] in
                guard running else { throw NotRunning() }
                // A connect that finds no helper spends its retry window.
                clock += .seconds(5)
                guard c.helperAnswers else { throw NotRunning() }
                return VMGuestHello(guestVersion: "1", accessibility: false, screenRecording: false,
                                    protocolRevision: VMGuestProtocol.revision, guestKind: "linux",
                                    capabilities: ["run"])
            },
            requestGuestPoweroff: {},
            stop: { [self] in
                running = false
            },
            seal: { [self] bundle in
                sealed = true
                try LinuxGoldenInstaller.writeSealedMarker(bundle)
            },
            sleep: { [self] duration in clock += duration },
            now: { [self] in clock })
    }
}
