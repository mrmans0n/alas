import Foundation
import Testing
@testable import Alas

@Suite("MemorySnapshot")
struct MemorySnapshotTests {
    @Test("oneLineLog formats bytes with binary suffixes and includes unattributed bucket")
    func oneLineLogFormatsBytes() {
        let snap = MemorySnapshot(
            timestamp: Date(timeIntervalSince1970: 0),
            physFootprint: 2_482_311_167,
            transcriptBytes: 1_524_000_000,
            markdownCacheBytes: 432_000_000,
            terminalBytes: 125_829_120,
            sessionCount: 14,
            runnerCount: 4,
            perSession: [])
        let line = snap.oneLineLog()
        #expect(line.hasPrefix("mem:"))
        #expect(line.contains("phys=2.31G"))
        #expect(line.contains("acp.tx=1.42G"))
        #expect(line.contains("acp.md=412M"))
        #expect(line.contains("term=120M"))
        #expect(line.contains("sessions=14"))
        #expect(line.contains("runners=4"))
        #expect(line.contains("unattributed="))
    }

    @Test("unattributed bucket equals phys minus accounted, floored at zero")
    func unattributedBucket() {
        let snap = MemorySnapshot(
            timestamp: Date(),
            physFootprint: 1_000_000_000,
            transcriptBytes: 100_000_000,
            markdownCacheBytes: 50_000_000,
            terminalBytes: 50_000_000,
            sessionCount: 0, runnerCount: 0, perSession: [])
        #expect(snap.unattributedBytes == 800_000_000)
    }

    @Test("unattributed clamps to zero when accounting overshoots phys")
    func unattributedFloor() {
        let snap = MemorySnapshot(
            timestamp: Date(),
            physFootprint: 100,
            transcriptBytes: 200,
            markdownCacheBytes: 0,
            terminalBytes: 0,
            sessionCount: 0, runnerCount: 0, perSession: [])
        #expect(snap.unattributedBytes == 0)
    }
}
