import AlasRemoteKit
import Foundation
import Testing
@testable import Alas

@MainActor
struct PeerDeviceSessionTests {
    @Test func replacedAttachmentCannotOpenMediaOrMutateCurrentViewer() throws {
        let origin = try #require(URL(string: "https://home.example.ts.net"))
        var requests: [PeerDeviceRequest] = []
        var ticketReceivers: [String: @MainActor (PeerDeviceVideoPacket) -> Void] = [:]
        var closed: [String] = []
        let session = PeerDeviceSession(send: { requests.append($0) }, verifiedOrigin: { origin }) {
            _, ticket, packet, _ in
            ticketReceivers[ticket] = packet
            return { closed.append(ticket) }
        }
        let a = device("A")
        let b = device("B")
        session.select(a)
        let old = try attachment(for: a, in: requests)
        session.receive(.attached(attachmentID: old, ticket: "A"))
        let sendOldPacket = try #require(ticketReceivers["A"])
        session.close()
        session.select(b)
        let current = try attachment(for: b, in: requests)
        session.receive(.attached(attachmentID: old, ticket: "late A"))
        session.receive(.attached(attachmentID: current, ticket: "B"))
        sendOldPacket(.format(generation: 1, width: 320, height: 480))
        sendOldPacket(.config(generation: 1, bytes: Data([0x01])))
        session.receive(.control(attachmentID: old, driver: .you, generation: 5))
        session.input(.button(.home))
        #expect(closed == ["A"])
        #expect(Set(ticketReceivers.keys) == ["A", "B"])
        #expect(session.selected == b)
        #expect(!session.canSendInput)
        #expect(requests == [
            .attach(deviceID: a.id, attachmentID: old), .detach(attachmentID: old),
            .attach(deviceID: b.id, attachmentID: current),
        ])
        session.close()
    }

    @Test func reconnectReopensSelectionWithFreshViewOnlyAttachment() throws {
        var origin = URL(string: "https://home.example.ts.net")
        let secure = try #require(origin)
        var requests: [PeerDeviceRequest] = []
        let session = PeerDeviceSession(send: { requests.append($0) }, verifiedOrigin: { origin })
        let a = device("A")
        session.select(a)
        let old = try attachment(for: a, in: requests)
        origin = nil
        session.connectionChanged()
        #expect(session.selected == a)
        #expect(!session.canSendInput)
        #expect(session.status == "Host unreachable.")
        origin = secure
        session.connectionChanged()
        #expect(requests.last == .list)
        session.receive(.list([a]))
        let new = try attachment(for: a, in: requests)
        #expect(new != old)
        #expect(requests.suffix(2) == [.list, .attach(deviceID: a.id, attachmentID: new)])
        session.close()
    }

    @Test func newFormatWillNotAcceptDependentFramesBeforeConfigOrKey() throws {
        let playback = PeerDevicePlayback()
        let delta = Data([0, 0, 1, 0x41, 0x88])
        _ = playback.receive(.format(generation: 1, width: 320, height: 480))
        _ = playback.receive(.format(generation: 2, width: 32, height: 16))
        #expect(playback.receive(.frame(generation: 1, pts: 10, keyFrame: true, bytes: delta)) == .waiting)
        #expect(playback.receive(.frame(generation: 2, pts: 20, keyFrame: false, bytes: delta)) == .waiting)
        // Baseline H.264 SPS/PPS for a 32 × 16 frame.
        let sps = try #require(Data(base64Encoded: "AAAAAWdCwAraLsBEAAADAAQAAAMACDxImoA="))
        let pps = try #require(Data(base64Encoded: "AAAAAWjOD8g="))
        #expect(playback.receive(.config(generation: 2, bytes: sps + pps)) == .accepted)
        #expect(playback.receive(.frame(generation: 2, pts: 30, keyFrame: false, bytes: delta)) == .waiting)
        #expect(playback.displayedGeneration == nil)
        #expect(playback.displayedSize == nil)
    }

    @Test(arguments: ["http://home.example.ts.net", "https://home.example.ts.net/other", "https://user@home.example.ts.net"])
    func mediaCannotOpenOnAnUnverifiedOrigin(address: String) throws {
        let url = try #require(URL(string: address))
        #expect(PeerDeviceMediaSocket.url(on: url) == nil)
    }

    @Test func mediaStaysOnVerifiedHostAndPortAndNeverFollowsRedirects() async throws {
        let origin = try #require(URL(string: "https://home.example.ts.net:8443"))
        let mediaURL = try #require(PeerDeviceMediaSocket.url(on: origin))
        #expect(mediaURL.absoluteString == "wss://home.example.ts.net:8443/ws/device-media")
        let redirect = try #require(URL(string: "https://other.example.ts.net/ws/device-media"))
        let response = try #require(HTTPURLResponse(url: mediaURL, statusCode: 307, httpVersion: nil, headerFields: nil))
        let task = URLSession.shared.webSocketTask(with: mediaURL)
        defer { task.cancel() }
        let allowed = await withCheckedContinuation { continuation in
            PeerDeviceMediaSocket.RedirectRefusal().urlSession(
                .shared, task: task, willPerformHTTPRedirection: response,
                newRequest: URLRequest(url: redirect)
            ) { continuation.resume(returning: $0) }
        }
        #expect(allowed == nil)
    }

    private func device(_ name: String) -> PeerDeviceSummary {
        .init(id: UUID(), name: name, access: .control, availability: .ready, driver: .available)
    }

    private func attachment(for device: PeerDeviceSummary, in requests: [PeerDeviceRequest]) throws -> UUID {
        let id = requests.reversed().compactMap { request -> UUID? in
            guard case .attach(let deviceID, let attachmentID) = request, deviceID == device.id else { return nil }
            return attachmentID
        }.first
        return try #require(id)
    }
}
