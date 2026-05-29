import Foundation
import Testing
@testable import Alas

@Suite("ProcessMemoryProbe")
struct ProcessMemoryProbeTests {
    @Test("physFootprint returns a non-zero kernel-reported value")
    func nonZero() {
        let bytes = ProcessMemoryProbe.physFootprint()
        #expect(bytes > 0)
    }

    @Test("physFootprint grows after we allocate a large buffer")
    func growsAfterAllocation() {
        let before = ProcessMemoryProbe.physFootprint()
        var ballast = [UInt8](repeating: 0xAB, count: 64 * 1024 * 1024)
        for i in stride(from: 0, to: ballast.count, by: 4096) {
            ballast[i] = 0xCD
        }
        let after = ProcessMemoryProbe.physFootprint()
        #expect(after > before)
        _ = ballast.count
    }
}
