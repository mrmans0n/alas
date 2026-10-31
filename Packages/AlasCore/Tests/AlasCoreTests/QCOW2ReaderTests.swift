import Darwin
import Foundation
import Testing
@testable import AlasPlatform

struct QCOW2ReaderTests {
    enum Defect: String, CaseIterable, Sendable {
        case compressedCluster, backingFile, encrypted, corruptBit, externalDataFile, unknownIncompatibleBit, shrink
    }

    @Test(arguments: [(UInt32(2), UInt64?.none), (3, nil), (3, 8 << 20)])
    func convertsTheFixtureToItsRawBytes(version: UInt32, growTo: UInt64?) throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("tiny.qcow2")
        try TinyQCOW2(version: version).write(to: image)
        let raw = dir.appendingPathComponent("disk.img")

        let reader = try QCOW2Reader(url: image)
        #expect(reader.virtualSize == TinyQCOW2.virtualSize)
        try reader.convertToRaw(at: raw, growTo: growTo)

        let bytes = try Data(contentsOf: raw)
        let size = growTo ?? TinyQCOW2.virtualSize
        #expect(UInt64(bytes.count) == size)
        #expect(bytes.prefix(Int(TinyQCOW2.virtualSize)) == TinyQCOW2.expectedRaw)
        #expect(bytes.dropFirst(Int(TinyQCOW2.virtualSize)).allSatisfy { $0 == 0 })
        // Unallocated and zero clusters are holes, not written zeros: writing
        // them would allocate the full 64.3 KiB (or 8 MiB when grown).
        var info = stat()
        #expect(stat(raw.path, &info) == 0)
        #expect(Int64(info.st_blocks) * 512 <= 64 * 1024)
    }

    @Test(arguments: Defect.allCases)
    func rejectsImagesItCannotReadFaithfully(defect: Defect) throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("tiny.qcow2")
        var fixture = TinyQCOW2(version: 3)
        switch defect {
        case .compressedCluster: fixture.compressFirstCluster = true
        case .backingFile: fixture.backingFileOffset = 4096
        case .encrypted: fixture.cryptMethod = 1
        case .corruptBit: fixture.incompatibleFeatures = 1 << 1
        case .externalDataFile: fixture.incompatibleFeatures = 1 << 2
        case .unknownIncompatibleBit: fixture.incompatibleFeatures = 1 << 5
        case .shrink: break
        }
        try fixture.write(to: image)
        let raw = dir.appendingPathComponent("disk.img")

        let expected: QCOW2ReaderError = switch defect {
        case .compressedCluster: .compressedCluster(guestOffset: 0)
        case .backingFile: .backingFile
        case .encrypted: .encrypted
        case .corruptBit, .externalDataFile, .unknownIncompatibleBit:
            .unsupportedIncompatibleFeatures(fixture.incompatibleFeatures)
        case .shrink: .cannotShrink(virtualSize: TinyQCOW2.virtualSize, requested: 4096)
        }
        #expect(throws: expected) {
            try QCOW2Reader(url: image).convertToRaw(at: raw, growTo: defect == .shrink ? 4096 : nil)
        }
        // A half-converted disk never stays behind.
        #expect(!FileManager.default.fileExists(atPath: raw.path))
    }

    private static func scratchDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qcow2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// Hand-writes a tiny qcow2 image, since `qemu-img` isn't on dev Macs or CI.
/// The layout follows docs/interop/qcow2.txt in QEMU and uses the smallest
/// legal cluster size (512 bytes) so each L2 table covers 64 guest clusters.
///
/// Host clusters: 0 header, 1 L1 table, 2 refcount table (empty), 3 L2 table
/// for guest clusters 0-63, 4 L2 table for guest clusters 128-191, 5-8 data.
///
/// Guest clusters, chosen to hit every read path:
/// - 0: data `0xA1` (host 5); with `compressFirstCluster` its entry is flagged compressed.
/// - 1: unallocated.
/// - 2: v3 zero flag over host 6, which holds `0xEE` garbage that must not leak; v2 leaves it unallocated.
/// - 3: data `0xB2` (host 7).
/// - 64-127: L1 entry 1 is zero, so the whole L2 table is unallocated.
/// - 128: data `0xC3` (host 8), cut short by the virtual size, which ends 300 bytes into it.
private struct TinyQCOW2 {
    static let clusterSize = 512
    static let virtualSize = UInt64(128 * clusterSize + 300)

    static var expectedRaw: Data {
        var data = Data(count: Int(virtualSize))
        data.replaceSubrange(0 ..< clusterSize, with: Data(repeating: 0xA1, count: clusterSize))
        data.replaceSubrange(3 * clusterSize ..< 4 * clusterSize, with: Data(repeating: 0xB2, count: clusterSize))
        data.replaceSubrange(128 * clusterSize ..< Int(virtualSize), with: Data(repeating: 0xC3, count: 300))
        return data
    }

    var version: UInt32
    var backingFileOffset: UInt64 = 0
    var cryptMethod: UInt32 = 0
    var incompatibleFeatures: UInt64 = 0
    var compressFirstCluster = false

    func write(to url: URL) throws {
        let copied: UInt64 = 1 << 63
        let host = { (cluster: Int) in UInt64(cluster * Self.clusterSize) }
        var image = Data(count: 9 * Self.clusterSize)
        func put(_ value: some FixedWidthInteger, at offset: Int) {
            withUnsafeBytes(of: value.bigEndian) { image.replaceSubrange(offset ..< offset + $0.count, with: $0) }
        }
        func fill(cluster: Int, with byte: UInt8) {
            let start = cluster * Self.clusterSize
            image.replaceSubrange(start ..< start + Self.clusterSize, with: Data(repeating: byte, count: Self.clusterSize))
        }

        // Header.
        image.replaceSubrange(0 ..< 4, with: [0x51, 0x46, 0x49, 0xFB])
        put(version, at: 4)
        put(backingFileOffset, at: 8)
        put(UInt32(backingFileOffset == 0 ? 0 : 8), at: 16)
        put(UInt32(9), at: 20) // cluster_bits
        put(Self.virtualSize, at: 24)
        put(cryptMethod, at: 32)
        put(UInt32(3), at: 36) // l1_size
        put(host(1), at: 40) // l1_table_offset
        put(host(2), at: 48) // refcount_table_offset
        put(UInt32(1), at: 56) // refcount_table_clusters
        if version >= 3 {
            put(incompatibleFeatures, at: 72)
            put(UInt32(4), at: 96) // refcount_order
            put(UInt32(104), at: 100) // header_length
        }

        // L1: entry 1 left zero (unallocated L2 table).
        put(host(3) | copied, at: Self.clusterSize)
        put(host(4) | copied, at: Self.clusterSize + 16)

        // L2 tables.
        let l2 = 3 * Self.clusterSize
        put(host(5) | copied | (compressFirstCluster ? 1 << 62 : 0), at: l2)
        if version >= 3 { put(host(6) | copied | 1, at: l2 + 2 * 8) }
        put(host(7) | copied, at: l2 + 3 * 8)
        put(host(8) | copied, at: 4 * Self.clusterSize)

        fill(cluster: 5, with: 0xA1)
        fill(cluster: 6, with: 0xEE)
        fill(cluster: 7, with: 0xB2)
        fill(cluster: 8, with: 0xC3)
        try image.write(to: url)
    }
}
