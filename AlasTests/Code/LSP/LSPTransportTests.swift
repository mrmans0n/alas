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
        #expect(source.validatesCachedDescendantsBeforeKilling())
        #expect(source.signalsProcessGroupFromTerminationHandler())
        #expect(source.signalsCachedDescendantsFromTerminationHandler())
        #expect(source.startsDescendantTrackingBeforeSetpgid())
        #expect(source.refreshesDescendantsOnFork())
        #expect(source.drainsPsOutputBeforeWaiting())
        #expect(source.validatesCachedDescendantsWithStableIdentity())
        #expect(source.checksRootExitBeforeTrackerRefresh())
        #expect(source.prunesCachedDescendantsWithBatchedLookup())
        #expect(source.tracksForksFromObservedDescendants())
        #expect(source.mergesDescendantRefreshesWithoutOverwritingCache())
    }

    @Test("JSONRPCStdioTransport snapshots live descendants before signaling root")
    func jsonrpcSnapshotsDescendantsBeforeRootSignal() throws {
        let source = try source(named: "JSONRPC/JSONRPCStdioTransport.swift")
        #expect(source.requiresLiveDescendantSnapshotBeforeRootSignal())
        #expect(source.validatesCachedDescendantsBeforeKilling())
        #expect(source.signalsProcessGroupFromTerminationHandler())
        #expect(source.signalsCachedDescendantsFromTerminationHandler())
        #expect(source.startsDescendantTrackingBeforeSetpgid())
        #expect(source.refreshesDescendantsOnFork())
        #expect(source.drainsPsOutputBeforeWaiting())
        #expect(source.validatesCachedDescendantsWithStableIdentity())
        #expect(source.checksRootExitBeforeTrackerRefresh())
        #expect(source.prunesCachedDescendantsWithBatchedLookup())
        #expect(source.tracksForksFromObservedDescendants())
        #expect(source.mergesDescendantRefreshesWithoutOverwritingCache())
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
        guard let snapshot = range(of: "let liveDescendants = Set(Self.collectDescendants(of: pid))") else {
            return false
        }
        return self[snapshot.upperBound...].contains("Darwin.kill(-pid, SIGTERM)")
    }

    func validatesCachedDescendantsBeforeKilling() -> Bool {
        contains("for d in Self.currentlyMatching(cachedTargets.subtracting(liveDescendants))")
    }

    func signalsProcessGroupFromTerminationHandler() -> Bool {
        guard let handler = range(of: "process.terminationHandler"),
              let rootExited = range(of: "self.rootHasExited = true"),
              let groupSignal = range(of: "Darwin.kill(-pid, SIGTERM)") else {
            return false
        }
        return handler.lowerBound < groupSignal.lowerBound && groupSignal.lowerBound < rootExited.lowerBound
    }

    func signalsCachedDescendantsFromTerminationHandler() -> Bool {
        guard let handler = range(of: "process.terminationHandler"),
              let cachedTargets = range(of: "let cachedTargets = self.orphanedDescendants"),
              let cachedSignal = range(of: "for d in Self.currentlyMatching(cachedTargets)"),
              let finish = range(of: "self.continuation?.finish()") else {
            return false
        }
        return handler.lowerBound < cachedTargets.lowerBound &&
            cachedTargets.lowerBound < cachedSignal.lowerBound &&
            cachedSignal.lowerBound < finish.lowerBound
    }

    func refreshesDescendantsOnFork() -> Bool {
        contains("eventMask: .fork") && contains("self?.refreshOrphanSet()")
    }

    func startsDescendantTrackingBeforeSetpgid() -> Bool {
        guard let run = range(of: "try process.run()"),
              let observer = range(of: "startDescendantForkObserver(for: process.processIdentifier)",
                                   range: run.upperBound..<endIndex),
              let refresh = range(of: "refreshOrphanSet()", range: observer.upperBound..<endIndex),
              let setpgid = range(of: "setpgid(process.processIdentifier", range: run.upperBound..<endIndex),
              let tracker = range(of: "startDescendantTracker()", range: setpgid.upperBound..<endIndex) else {
            return false
        }
        return run.lowerBound < observer.lowerBound &&
            observer.lowerBound < refresh.lowerBound &&
            refresh.lowerBound < setpgid.lowerBound &&
            setpgid.lowerBound < tracker.lowerBound
    }

    func drainsPsOutputBeforeWaiting() -> Bool {
        guard let collect = range(of: "private static func collectDescendants"),
              let read = range(
                  of: "data = pipe.fileHandleForReading.readDataToEndOfFile()",
                  range: collect.upperBound..<endIndex
              ),
              let wait = range(of: "proc.waitUntilExit()", range: collect.upperBound..<endIndex) else {
            return false
        }
        return read.lowerBound < wait.lowerBound
    }

    func validatesCachedDescendantsWithStableIdentity() -> Bool {
            contains("let startedAt: String") &&
            contains(#""pid=,ppid=,lstart=,comm=""#) &&
            contains(#""pid=,lstart=,comm=""#) &&
            !contains("current.pgid == key.pgid") &&
            contains("startedAt: parts[1...5].joined(separator: \" \")") &&
            contains("return current.intersection(keys)")
    }

    func checksRootExitBeforeTrackerRefresh() -> Bool {
        guard let tracker = range(of: "private func startDescendantTracker()"),
              let refresh = range(of: "self.refreshOrphanSet()", range: tracker.upperBound..<endIndex),
              let rootExited = range(of: "let shouldStop = self.rootHasExited", range: tracker.upperBound..<endIndex) else {
            return false
        }
        return rootExited.lowerBound < refresh.lowerBound
    }

    func prunesCachedDescendantsWithBatchedLookup() -> Bool {
        contains("private static func currentlyMatching(_ keys: Set<DescendantKey>) -> Set<DescendantKey>") &&
            contains("let retained = Self.currentlyMatching(cached)") &&
            contains("orphanedDescendants.subtract(cached.subtracting(retained))") &&
            contains("orphanedDescendants.formUnion(live)") &&
            contains("for d in Self.currentlyMatching(targets)")
    }

    func tracksForksFromObservedDescendants() -> Bool {
        contains("private var descendantForkSources: [pid_t: DispatchSourceProcess] = [:]") &&
            contains("private func startDescendantForkObserver(for pid: pid_t)") &&
            contains("for pid in descendants.map(\\.pid)") &&
            contains("startDescendantForkObserver(for: pid)")
    }

    func mergesDescendantRefreshesWithoutOverwritingCache() -> Bool {
        guard let retained = range(of: "let retained = Self.currentlyMatching(cached)"),
              let subtract = range(of: "orphanedDescendants.subtract(cached.subtracting(retained))",
                                   range: retained.upperBound..<endIndex),
              let union = range(of: "orphanedDescendants.formUnion(live)",
                                range: retained.upperBound..<endIndex) else {
            return false
        }
        return retained.lowerBound < subtract.lowerBound &&
            subtract.lowerBound < union.lowerBound
    }
}
