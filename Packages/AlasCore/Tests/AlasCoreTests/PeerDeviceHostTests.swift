import Foundation
import Testing
import AlasCore
@testable import AlasHostCore

@MainActor
struct PeerDeviceHostTests {
    @Test func lateMediaCloseCannotDetachReplacementAndParentLossClosesIt() throws {
        let fixture = try DeviceHostFixture()
        defer { fixture.cleanUp() }
        let link = fixture.connect()
        let attachment = UUID()
        let first = try fixture.openMedia(link: link, attachment: attachment)
        fixture.host.handle(.detach(attachmentID: attachment), from: link)
        #expect(fixture.closedMedia == 1)

        let replacement = try fixture.openMedia(link: link, attachment: attachment)
        fixture.host.mediaClosed(first)
        #expect(fixture.closedMedia == 1)

        let newParent = fixture.connect()
        _ = try fixture.openMedia(link: newParent, attachment: attachment)
        fixture.host.disconnect(link)
        #expect(fixture.closedMedia == 2)
        fixture.host.mediaClosed(replacement)
        #expect(fixture.closedMedia == 2)
        fixture.host.disconnect(link)
        #expect(fixture.closedMedia == 2)
        fixture.host.disconnect(newParent)
        #expect(fixture.closedMedia == 3)
    }

    @Test func lossInvalidatesInputBeforeCleanupAndOldGenerationsDoNotReachReplacement() async throws {
        let fixture = try DeviceHostFixture()
        defer { fixture.cleanUp() }
        let link = fixture.connect()
        let oldAttachment = UUID()
        let newAttachment = UUID()
        let media = try fixture.openMedia(link: link, attachment: oldAttachment)
        fixture.host.handle(.takeControl(attachmentID: oldAttachment), from: link)
        try await eventually { await fixture.generation(for: oldAttachment) != nil }
        let generation = try #require(fixture.generation(for: oldAttachment))
        let pointer = PeerDeviceInput.pointer(phase: .begin, x: 0.5, y: 0.5)
        fixture.host.handle(.input(attachmentID: oldAttachment, leaseGeneration: generation,
                                   formatGeneration: 1, event: pointer), from: link)
        #expect(fixture.input == [pointer])

        fixture.holdCleanup = true
        defer { fixture.finishCleanup() }
        fixture.host.mediaClosed(media)
        #expect(fixture.freezes == 1)
        #expect(!fixture.cleanupBegan)
        fixture.host.handle(.input(attachmentID: oldAttachment, leaseGeneration: generation,
                                   formatGeneration: 1, event: pointer), from: link)
        _ = try fixture.openMedia(link: link, attachment: newAttachment)
        #expect(fixture.captureStarts == 1)
        #expect(fixture.captureStops == 0)
        fixture.host.handle(.takeControl(attachmentID: newAttachment), from: link)
        try await eventually { await fixture.cleanupBegan }
        #expect(fixture.input == [pointer])
        #expect(fixture.generation(for: newAttachment) == nil)

        fixture.finishCleanup()
        try await eventually { await fixture.releaseFinished }
        fixture.host.handle(.takeControl(attachmentID: newAttachment), from: link)
        try await eventually { await fixture.generation(for: newAttachment) != nil }
        let replacement = try #require(fixture.generation(for: newAttachment))
        #expect(replacement != generation)
        for (lease, format) in [(generation, 1 as UInt64), (replacement, 2)] {
            fixture.host.handle(.input(attachmentID: newAttachment, leaseGeneration: lease,
                                       formatGeneration: format, event: pointer), from: link)
        }
        #expect(fixture.input == [pointer])
        fixture.host.handle(.input(attachmentID: newAttachment, leaseGeneration: replacement,
                                   formatGeneration: 1, event: pointer), from: link)
        #expect(fixture.input == [pointer, pointer])
        fixture.host.handle(.detach(attachmentID: newAttachment), from: link)
        #expect(fixture.captureStops == 0)
        try await eventually { await fixture.captureStops == 1 }
        #expect(fixture.releases == 2)
    }

    @Test func downgradingKeepsVideoButRevokingClosesIt() async throws {
        let fixture = try DeviceHostFixture()
        defer { fixture.cleanUp() }
        let link = fixture.connect()
        let attachment = UUID()
        _ = try fixture.openMedia(link: link, attachment: attachment)
        fixture.host.handle(.takeControl(attachmentID: attachment), from: link)
        try await eventually { await fixture.generation(for: attachment) != nil }
        let generation = try #require(fixture.generation(for: attachment))

        try fixture.grants.setAccess(.view, serial: "test", name: "Android", pairingID: "paired")
        fixture.host.refresh()
        fixture.host.handle(.input(attachmentID: attachment, leaseGeneration: generation,
                                   formatGeneration: 1, event: .button(.back)), from: link)
        #expect(fixture.input.isEmpty)
        #expect(fixture.generation(for: attachment) == nil)
        #expect(fixture.closedMedia == 0)
        try await eventually { await fixture.releaseFinished }

        try fixture.grants.stopSharing(serial: "test")
        fixture.host.refresh()
        #expect(fixture.closedMedia == 1)
        fixture.host.handle(.list, from: link)
        #expect(fixture.events.last == .list([]))
    }

    @Test func expiredLeaseCannotBeRevivedByLateRenewalOrInput() async throws {
        let fixture = try DeviceHostFixture()
        fixture.interceptExpiry = true
        defer { fixture.cleanUp() }
        let link = fixture.connect()
        let attachment = UUID()
        _ = try fixture.openMedia(link: link, attachment: attachment)
        fixture.host.handle(.takeControl(attachmentID: attachment), from: link)
        try await eventually { await fixture.generation(for: attachment) != nil }
        let generation = try #require(fixture.generation(for: attachment))

        fixture.now = .seconds(2)
        fixture.host.handle(.renewControl(attachmentID: attachment, generation: generation), from: link)
        fixture.now = .seconds(6)
        fixture.host.handle(.input(attachmentID: attachment, leaseGeneration: generation,
                                   formatGeneration: 1, event: .button(.back)), from: link)
        #expect(fixture.input == [.button(.back)])
        try await eventually { await fixture.expiryScheduled }
        fixture.now = .seconds(8)
        fixture.wakeExpiry()
        // No requests or socket teardown are needed to release a silent lease.
        try await eventually { await fixture.releaseFinished }
        fixture.host.handle(.renewControl(attachmentID: attachment, generation: generation), from: link)
        fixture.host.handle(.input(attachmentID: attachment, leaseGeneration: generation,
                                   formatGeneration: 1, event: .button(.back)), from: link)
        #expect(fixture.input == [.button(.back)])
        #expect(fixture.generation(for: attachment) == nil)
    }

    @Test func quitStopsAdmissionAndWaitsForCleanup() async throws {
        let fixture = try DeviceHostFixture()
        defer { fixture.cleanUp() }
        let link = fixture.connect()
        let attachment = UUID()
        _ = try fixture.openMedia(link: link, attachment: attachment)
        fixture.host.handle(.takeControl(attachmentID: attachment), from: link)
        try await eventually { await fixture.generation(for: attachment) != nil }

        fixture.holdCleanup = true
        defer { fixture.finishCleanup() }
        var quitReturned = false
        let quitting = Task { @MainActor in
            await fixture.host.shutdownAndWait(upTo: .seconds(10))
            quitReturned = true
        }
        try await eventually { await fixture.cleanupBegan }
        #expect(!quitReturned)
        #expect(fixture.closedMedia == 1)
        #expect(fixture.captureStops == 0)

        let concurrentLink = fixture.connect()
        fixture.host.handle(.list, from: concurrentLink)
        #expect(fixture.events.last == .list([]))
        let newAttachment = UUID()
        fixture.host.handle(.attach(deviceID: fixture.deviceID, attachmentID: newAttachment), from: concurrentLink)
        guard case .refused(let id, _)? = fixture.events.last else {
            Issue.record("Quit should refuse a new attachment")
            return
        }
        #expect(id == newAttachment)
        fixture.finishCleanup()
        await quitting.value
        #expect(fixture.releaseFinished)
        #expect(fixture.captureStops == 1)
    }

    @Test(.timeLimit(.minutes(5)))
    func aBlockedTakeoverDoesNotHoldQuitIndefinitely() async throws {
        let fixture = try DeviceHostFixture()
        defer { fixture.cleanUp() }
        let link = fixture.connect()
        let attachment = UUID()
        _ = try fixture.openMedia(link: link, attachment: attachment)
        fixture.holdAcquisition = true
        defer { fixture.finishAcquisition() }
        fixture.host.handle(.takeControl(attachmentID: attachment), from: link)
        try await eventually { await fixture.acquisitionPending }

        await fixture.host.shutdownAndWait(upTo: .milliseconds(30))
        #expect(fixture.acquisitionPending)
        #expect(fixture.closedMedia == 1)
        #expect(fixture.generation(for: attachment) == nil)

        fixture.finishAcquisition()
        // A backend that finishes acquiring despite cancellation still has
        // to clean up. It was never allowed to admit remote events.
        try await eventually { await fixture.releaseFinished }
        #expect(fixture.generation(for: attachment) == nil)
    }
}

@MainActor
private final class DeviceHostFixture {
    let directory: URL
    let grants: PeerDeviceGrants
    let deviceID: PeerDeviceID
    private let videoTime = ContinuousClock.now
    var now: Duration = .zero
    var closedMedia = 0
    var captureStarts = 0
    var captureStops = 0
    var freezes = 0
    var releases = 0
    var events: [PeerDeviceEvent] = []
    var input: [PeerDeviceInput] = []
    var holdCleanup = false
    var cleanupBegan = false
    var releaseFinished = false
    private var cleanupContinuation: CheckedContinuation<Void, Never>?
    var holdAcquisition = false
    private var acquisitionWaiter: CheckedContinuation<Void, Never>?
    var acquisitionPending: Bool { acquisitionWaiter != nil }
    var interceptExpiry = false
    private var expiryWaiter: CheckedContinuation<Void, Never>?
    var expiryScheduled: Bool { expiryWaiter != nil }

    lazy var host = makeHost()

    private func makeHost() -> PeerDeviceHost {
        PeerDeviceHost(grants: grants, environment: .init(
            eligible: { true }, availability: { _ in .ready }, driver: { _ in .available },
            subscribe: { [weak self] _, packet, _ in
                self?.captureStarts += 1
                packet(.format(generation: 1, width: 720, height: 1600))
                return UUID()
            }, unsubscribe: { [weak self] _, _ in self?.captureStops += 1 },
            acquire: { [weak self] _, _ in
                guard let self else { return false }
                if holdAcquisition { await withCheckedContinuation { acquisitionWaiter = $0 } }
                return true
            },
            freezeInput: { [weak self] _, _ in self?.freezes += 1 },
            release: { [weak self] _, _ in
                guard let self else { return }
                cleanupBegan = true
                if holdCleanup { await withCheckedContinuation { cleanupContinuation = $0 } }
                releases += 1
                releaseFinished = true
            }, input: { [weak self] _, _, _, input in self?.input.append(input) }
        ), now: { [weak self] in self?.now ?? .zero }, videoNow: { [videoTime] in videoTime }, waitForExpiry: { [weak self] delay in
            guard let self else { return }
            if interceptExpiry {
                await withCheckedContinuation { expiryWaiter = $0 }
            } else {
                try await Task.sleep(for: delay)
            }
        })
    }

    init() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = try PeerDeviceGrants(file: folder.appendingPathComponent("grants.json"))
        directory = folder
        grants = store
        deviceID = try store.setAccess(.control, serial: "test", name: "Android", pairingID: "paired")
    }

    func cleanUp() {
        host.shutdown()
        wakeExpiry()
        try? FileManager.default.removeItem(at: directory)
    }

    func wakeExpiry() {
        let waiter = expiryWaiter
        expiryWaiter = nil
        waiter?.resume()
    }

    func connect() -> UUID {
        host.connect(pairingID: "paired", name: "Phone", authorized: { true }) { [weak self] in self?.events.append($0) }
    }

    func openMedia(link: UUID, attachment: UUID) throws -> PeerDeviceHost.MediaSession {
        host.handle(.attach(deviceID: deviceID, attachmentID: attachment), from: link)
        let ticket = try #require(events.last.flatMap { event -> String? in
            guard case .attached(let id, let ticket) = event, id == attachment else { return nil }
            return ticket
        })
        let claimed = host.claimMedia(ticket: ticket, write: { _, complete in complete() }, close: { [weak self] in
            self?.closedMedia += 1
        }, isOpen: { true })
        let media = try #require(claimed)
        host.startMedia(media)
        return media
    }

    func generation(for attachment: UUID) -> UInt64? {
        guard let event = events.last(where: {
            if case .control(let id, _, _) = $0 { return id == attachment }
            return false
        }), case .control(_, .you, let generation) = event else { return nil }
        return generation
    }

    func finishCleanup() {
        holdCleanup = false
        cleanupContinuation?.resume()
        cleanupContinuation = nil
    }

    func finishAcquisition() {
        holdAcquisition = false
        let waiter = acquisitionWaiter
        acquisitionWaiter = nil
        waiter?.resume()
    }
}
