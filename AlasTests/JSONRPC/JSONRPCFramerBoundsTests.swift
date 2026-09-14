import Foundation
import Testing
@testable import Alas

struct JSONRPCFramerBoundsTests {
    @Test func drainsMaximumFrameBeforeCheckingFollowingFrameInSameRead() {
        var framer = JSONRPCFramer()
        let maximumBody = Data(repeating: 65, count: 16 * 1024 * 1024)
        let followingBody = Data(repeating: 66, count: 16 * 1024)
        let maximumFrame = JSONRPCFramer.encode(maximumBody)
        let split = maximumFrame.count - 1024
        framer.append(maximumFrame.prefix(split))
        #expect(framer.drainFrames().isEmpty)
        #expect(!framer.hasFailed)

        var combinedRead = Data(maximumFrame.suffix(1024))
        combinedRead.append(JSONRPCFramer.encode(followingBody))
        framer.append(combinedRead)
        let frames = framer.drainFrames()
        #expect(!framer.hasFailed)
        #expect(frames == [maximumBody, followingBody])
    }

    @Test func rejectsOversizedDeclarationBeforeReceivingBody() {
        var framer = JSONRPCFramer()
        framer.append(Data("Content-Length: 16777217\r\n\r\n".utf8))
        #expect(framer.drainFrames().isEmpty)
        #expect(framer.hasFailed)
        framer.append(JSONRPCFramer.encode(Data("{}".utf8)))
        #expect(framer.drainFrames().isEmpty)
    }

    @Test func rejectsOversizedBody() {
        var framer = JSONRPCFramer()
        let body = Data(repeating: 32, count: 16 * 1024 * 1024 + 1)
        framer.append(JSONRPCFramer.encode(body))
        #expect(framer.drainFrames().isEmpty)
    }

    @Test func rejectsOversizedHeader() {
        var framer = JSONRPCFramer()
        let header = "Extra: " + String(repeating: "x", count: 8192) + "\r\nContent-Length: 2\r\n\r\n{}"
        framer.append(Data(header.utf8))
        #expect(framer.drainFrames().isEmpty)
    }
}

struct JSONRPCStdioFramingFailureTests {
    @Test func contentLengthFailureEndsConsumersWhileChildIsStillWaiting() async throws {
        let transport = JSONRPCStdioTransport(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'Content-Length: 16777217\\r\\n\\r\\n'; read value"],
            environment: nil, framing: .contentLength, terminationScope: .processOnly
        )
        defer { transport.terminate() }
        try transport.start()
        let ended = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in transport.incoming {}
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        #expect(ended)
    }
}
