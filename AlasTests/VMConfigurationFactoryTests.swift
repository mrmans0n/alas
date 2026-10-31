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

    #if arch(arm64)
    @Test("a Linux bundle with its seed and shares makes a configuration Virtualization accepts")
    func linuxConfigurationValidates() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VMConfigurationFactoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = LinuxVMBundle(url: dir)
        try Data(count: 1 << 20).write(to: bundle.diskImage)
        try bundle.writeIdentity()
        let seed = dir.appendingPathComponent("seed.iso")
        try Data(count: 1 << 16).write(to: seed)

        let configuration = try VMConfigurationFactory.linux(
            bundle: bundle, cpuCount: 2, memoryBytes: 4 * Self.gib, display: .default,
            shares: [VMShare(name: "helper", hostURL: dir, readOnly: true)], seedISO: seed)

        #expect(configuration.storageDevices.count == 2)
        #expect(configuration.audioDevices.isEmpty)
    }
    #endif
}
