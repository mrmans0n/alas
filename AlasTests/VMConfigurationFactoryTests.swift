import Foundation
import Testing
@testable import Alas

@Suite("VMConfigurationFactory")
struct VMConfigurationFactoryTests {
    private static let gib: UInt64 = 1 << 30

    @Test(
        "default resources take half the CPUs and a quarter of the memory, clamped",
        arguments: [
            (4, 8 * gib, 2, 4 * gib),
            (12, 36 * gib, 6, 9 * gib),
            (24, 128 * gib, 8, 16 * gib),
        ])
    func defaultResourcesClamp(hostCPUs: Int, hostMemory: UInt64, cpus: Int, memory: UInt64) {
        let resources = VMConfigurationFactory.defaultResources(hostCPUs: hostCPUs, hostMemory: hostMemory)
        #expect(resources.cpus == cpus)
        #expect(resources.memory == memory)
    }
}
