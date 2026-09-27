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
}
