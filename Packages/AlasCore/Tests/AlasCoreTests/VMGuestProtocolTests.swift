import Foundation
import Testing
@testable import AlasPlatform

struct VMGuestProtocolTests {
    private let messages: [VMGuestMessage] = [
        .command(id: 1, sessionID: "s", request: Data(#"{"command":"computer_apps"}"#.utf8)),
        .runResult(id: 2, exitCode: nil, stdout: "out", stderr: "", truncated: false, timedOut: true),
        .helloReply(guestVersion: "1.0", protocolRevision: VMGuestProtocol.revision, accessibility: true, screenRecording: false),
    ]

    @Test(arguments: [1, 3, 10_000])
    func framerReassemblesSplitAndCoalescedFrames(sliceSize: Int) throws {
        var stream = Data()
        for message in messages { stream.append(try VMGuestFramer.frame(message)) }
        var framer = VMGuestFramer()
        var received: [VMGuestMessage] = []
        var offset = 0
        while offset < stream.count {
            let end = min(offset + sliceSize, stream.count)
            received += framer.append(stream[offset..<end]).messages
            offset = end
        }
        #expect(received == messages)
    }

    @Test func framerSkipsMalformedFramesWithoutLosingNeighbours() throws {
        var framer = VMGuestFramer()
        let garbage = Data([0, 0, 0, 3]) + Data("{x}".utf8)
        let stream = try VMGuestFramer.frame(.cancel(id: 1)) + garbage + VMGuestFramer.frame(.cancel(id: 2))
        let output = framer.append(stream)
        #expect(output.messages == [.cancel(id: 1), .cancel(id: 2)])
        #expect(output.malformedFrames == 1)
    }

    @Test func helloReplyFromBeforeRevisionsDecodesAsRevisionZero() throws {
        let json = Data(#"{"type":"helloReply","guestVersion":"1.0","accessibility":true,"screenRecording":true}"#.utf8)
        let message = try JSONDecoder().decode(VMGuestMessage.self, from: json)
        #expect(message == .helloReply(guestVersion: "1.0", protocolRevision: 0, accessibility: true, screenRecording: true))
    }
}
