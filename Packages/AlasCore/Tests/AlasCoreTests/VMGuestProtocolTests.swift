import Foundation
import Testing
@testable import AlasPlatform

struct VMGuestProtocolTests {
    private let messages: [VMGuestMessage] = [
        .command(id: 1, sessionID: "s", request: Data(#"{"command":"computer_apps"}"#.utf8)),
        .runResult(id: 2, exitCode: nil, stdout: "out", stderr: "", truncated: false, timedOut: true),
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
            received += try framer.append(stream[offset..<end])
            offset = end
        }
        #expect(received == messages)
    }

    @Test func framerThrowsOnMalformedCompleteFrameThenRecovers() throws {
        var framer = VMGuestFramer()
        let bad = Data([0, 0, 0, 3]) + Data("{x}".utf8)
        #expect(throws: (any Error).self) { try framer.append(bad) }
        #expect(try framer.append(VMGuestFramer.frame(.cancel(id: 9))) == [.cancel(id: 9)])
    }
}
