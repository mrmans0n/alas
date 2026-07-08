import Foundation
import Testing
@testable import Alas

@Suite("LSPTransport.framing")
struct LSPTransportFramingTests {
    @Test("decodes a single frame")
    func singleFrame() async throws {
        let body = #"{"jsonrpc":"2.0","id":1,"result":null}"#
        let bytes = makeFrame(body)
        var decoder = JSONRPCFramer()
        decoder.append(bytes)
        let frames = decoder.drainFrames()
        #expect(frames.count == 1)
        #expect(String(data: frames[0], encoding: .utf8) == body)
    }

    @Test("decodes two concatenated frames")
    func twoFrames() async throws {
        let a = #"{"jsonrpc":"2.0","method":"a"}"#
        let b = #"{"jsonrpc":"2.0","method":"b"}"#
        var decoder = JSONRPCFramer()
        decoder.append(makeFrame(a) + makeFrame(b))
        let frames = decoder.drainFrames()
        #expect(frames.count == 2)
        #expect(String(data: frames[0], encoding: .utf8) == a)
        #expect(String(data: frames[1], encoding: .utf8) == b)
    }

    @Test("decodes a frame split across two appends")
    func splitFrame() async throws {
        let body = #"{"jsonrpc":"2.0","id":7,"result":1}"#
        let frame = makeFrame(body)
        var decoder = JSONRPCFramer()
        decoder.append(frame.prefix(10))
        #expect(decoder.drainFrames().isEmpty)
        decoder.append(frame.suffix(from: 10))
        let frames = decoder.drainFrames()
        #expect(frames.count == 1)
        #expect(String(data: frames[0], encoding: .utf8) == body)
    }

    private func makeFrame(_ body: String) -> Data {
        let payload = body.data(using: .utf8)!
        var out = "Content-Length: \(payload.count)\r\n\r\n".data(using: .utf8)!
        out.append(payload)
        return out
    }
}

@Suite("Process transport termination")
struct ProcessTransportTerminationTests {
    @Test("LSPTransport snapshots live descendants before signaling root")
    func lspSnapshotsDescendantsBeforeRootSignal() throws {
        let source = try source(named: "Code/LSP/LSPTransport.swift")
        #expect(source.requiresLiveDescendantSnapshotBeforeRootSignal())
    }

    @Test("JSONRPCStdioTransport snapshots live descendants before signaling root")
    func jsonrpcSnapshotsDescendantsBeforeRootSignal() throws {
        let source = try source(named: "JSONRPC/JSONRPCStdioTransport.swift")
        #expect(source.requiresLiveDescendantSnapshotBeforeRootSignal())
    }

    private func source(named path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Alas/Sources/\(path)"),
                          encoding: .utf8)
    }
}

private extension String {
    func requiresLiveDescendantSnapshotBeforeRootSignal() -> Bool {
        guard let snapshot = range(of: "let liveDescendants = Self.collectDescendants(of: pid)"),
              let groupSignal = range(of: "Darwin.kill(-pid, SIGTERM)") else {
            return false
        }
        return snapshot.lowerBound < groupSignal.lowerBound
    }
}
