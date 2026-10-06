import Foundation
import Testing
@testable import Alas

@Suite("JSONRPCFramer")
struct JSONRPCFramerTests {
    @Test("decodes a single Content-Length framed payload")
    func singleFrame() {
        var framer = JSONRPCFramer()
        let body = #"{"jsonrpc":"2.0","id":1,"method":"x"}"#
        let bytes = "Content-Length: \(body.utf8.count)\r\n\r\n\(body)".data(using: .utf8)!
        framer.append(bytes)
        let frames = framer.drainFrames()
        #expect(frames.count == 1)
        #expect(String(data: frames[0], encoding: .utf8) == body)
    }

    @Test("decodes two frames delivered in one chunk")
    func twoFramesOneChunk() {
        var framer = JSONRPCFramer()
        let a = #"{"a":1}"#
        let b = #"{"b":2}"#
        let blob = "Content-Length: \(a.utf8.count)\r\n\r\n\(a)Content-Length: \(b.utf8.count)\r\n\r\n\(b)"
        framer.append(blob.data(using: .utf8)!)
        let frames = framer.drainFrames().compactMap { String(data: $0, encoding: .utf8) }
        #expect(frames == [a, b])
    }

    @Test("buffers partial frames across appends")
    func partialChunks() {
        var framer = JSONRPCFramer()
        let body = #"{"x":1}"#
        let full = "Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let cut = full.index(full.startIndex, offsetBy: 8)
        framer.append(String(full[..<cut]).data(using: .utf8)!)
        #expect(framer.drainFrames().isEmpty)
        framer.append(String(full[cut...]).data(using: .utf8)!)
        let frames = framer.drainFrames()
        #expect(frames.count == 1)
        #expect(String(data: frames[0], encoding: .utf8) == body)
    }

    @Test("encodes a body with Content-Length header")
    func encode() {
        let body = #"{"a":1}"#.data(using: .utf8)!
        let framed = JSONRPCFramer.encode(body)
        let expected = "Content-Length: \(body.count)\r\n\r\n".data(using: .utf8)! + body
        #expect(framed == expected)
    }

    @Test("newline frames preserve partial tails, CRLF and empty lines", arguments: [1, 2, 7, 64])
    func newlineFramesAcrossChunks(chunkSize: Int) {
        var framer = JSONRPCNewlineFramer()
        let input = Data("\n\r\n{\"a\":1}\r\n{\"b\":2}\npartial".utf8)
        var frames: [Data] = []
        for offset in stride(from: 0, to: input.count, by: chunkSize) {
            framer.append(input[offset..<min(offset + chunkSize, input.count)])
            frames += framer.drainFrames()
        }
        #expect(frames == [Data(#"{"a":1}"#.utf8), Data(#"{"b":2}"#.utf8)])
        #expect(framer.drainFrames().isEmpty)
        framer.append(Data(" tail\r\nnext\n".utf8))
        #expect(framer.drainFrames() == [Data("partial tail".utf8), Data("next".utf8)])
    }

    @Test("large newline frames drain without rescanning every previous chunk")
    func largeNewlineFrameMakesProgress() {
        var framer = JSONRPCNewlineFramer()
        let chunk = Data(repeating: 120, count: 16 * 1024)
        let started = ContinuousClock.now
        for _ in 0..<512 {
            framer.append(chunk)
            #expect(framer.drainFrames().isEmpty)
        }
        framer.append([10])
        let frames = framer.drainFrames()
        #expect(frames == [Data(repeating: 120, count: 8 * 1024 * 1024)])
        // Linear parsing takes milliseconds; the original rescan takes seconds
        // even in an optimized build. Leave headroom for loaded CI machines.
        #expect(started.duration(to: .now) < .seconds(4))
    }
}
