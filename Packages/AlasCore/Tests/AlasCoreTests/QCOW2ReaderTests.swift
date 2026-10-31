import Compression
import Darwin
import Foundation
import Testing
@testable import AlasPlatform

struct QCOW2ReaderTests {
    enum Defect: String, CaseIterable, Sendable {
        case backingFile, encrypted, corruptBit, externalDataFile, unknownIncompatibleBit
        case zstdFeatureBit, zstdCompressionType, badDeflate, shortHeaderLength
        case hugeVirtualSize, hugeL1Size, hugeL1Offset, l1EndPastInt64
        case misalignedL2Table, misalignedDataCluster
        case shrink, hugeGrowTo
    }

    @Test(arguments: [
        (UInt32(2), 9, UInt64?.none), (3, 9, nil), (3, 9, 1 << 30), (3, 10, nil),
    ] as [(UInt32, UInt64, UInt64?)])
    func convertsTheFixtureToItsRawBytes(version: UInt32, clusterBits: UInt64, growTo: UInt64?) throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("tiny.qcow2")
        let fixture = TinyQCOW2(version: version, clusterBits: clusterBits)
        try fixture.write(to: image)
        let raw = dir.appendingPathComponent("disk.img")

        let reader = try QCOW2Reader(url: image)
        #expect(reader.virtualSize == fixture.virtualSize)
        try reader.convertToRaw(at: raw, growTo: growTo)

        var info = stat()
        #expect(stat(raw.path, &info) == 0)
        #expect(UInt64(info.st_size) == growTo ?? fixture.virtualSize)
        let handle = try FileHandle(forReadingFrom: raw)
        defer { try? handle.close() }
        #expect(try handle.read(upToCount: Int(fixture.virtualSize)) == fixture.expectedRaw)
        let tail = try handle.read(upToCount: 64 * 1024) ?? Data()
        #expect(tail.allSatisfy { $0 == 0 })
        // Unallocated clusters and the grown tail are holes, not written zeros.
        // Only checked on the grown disk: APFS allocates small files (a few
        // MiB) in full once written to, however sparse they were made.
        if growTo != nil {
            #expect(Int64(info.st_blocks) * 512 <= 1 << 20)
        }
    }

    @Test(arguments: Defect.allCases)
    func rejectsImagesItCannotReadFaithfully(defect: Defect) throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("tiny.qcow2")
        // 1 KiB clusters, so a 512-byte offset is a misaligned one.
        var fixture = TinyQCOW2(version: 3, clusterBits: 10)
        var growTo: UInt64?
        let expected: QCOW2ReaderError
        switch defect {
        case .backingFile:
            fixture.backingFileOffset = 4096
            expected = .backingFile
        case .encrypted:
            fixture.cryptMethod = 1
            expected = .encrypted
        case .corruptBit, .externalDataFile, .unknownIncompatibleBit, .zstdFeatureBit:
            let bit: UInt64 = switch defect {
            case .corruptBit: 1
            case .externalDataFile: 2
            case .zstdFeatureBit: 3
            default: 5
            }
            fixture.incompatibleFeatures = 1 << bit
            expected = .unsupportedIncompatibleFeatures(1 << bit)
        case .zstdCompressionType:
            fixture.compressionType = 1
            expected = .unsupportedCompressionType(1)
        case .badDeflate:
            fixture.corruptDeflate = true
            expected = .invalidCompressedCluster(guestOffset: 4 * fixture.clusterSize)
        case .shortHeaderLength:
            fixture.headerLength = 72
            expected = .invalidHeaderLength(72)
        case .hugeVirtualSize:
            fixture.virtualSizeOverride = 1 << 57
            expected = .sizeTooLarge(1 << 57)
        case .hugeL1Size:
            fixture.l1SizeOverride = .max
            expected = .l1TableTooLarge(.max)
        case .hugeL1Offset:
            fixture.l1TableOffsetOverride = 1 << 63
            expected = .invalidL1TableOffset(1 << 63)
        case .l1EndPastInt64:
            // Aligned and below Int64.max, but a maximal 32 MiB table runs past it.
            let offset = UInt64(Int64.max) & ~UInt64(1023)
            fixture.l1TableOffsetOverride = offset
            fixture.l1SizeOverride = 4 << 20
            expected = .invalidL1TableOffset(offset)
        case .misalignedL2Table:
            fixture.l2TableMisalignment = 512
            expected = .misalignedCluster(hostOffset: 3 * fixture.clusterSize + 512)
        case .misalignedDataCluster:
            fixture.dataMisalignment = 512
            expected = .misalignedCluster(hostOffset: 5 * fixture.clusterSize + 512)
        case .shrink:
            growTo = 4096
            expected = .cannotShrink(virtualSize: fixture.virtualSize, requested: 4096)
        case .hugeGrowTo:
            growTo = .max
            expected = .sizeTooLarge(.max)
        }
        try fixture.write(to: image)
        let raw = dir.appendingPathComponent("disk.img")

        #expect(throws: expected) {
            try QCOW2Reader(url: image).convertToRaw(at: raw, growTo: growTo)
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
/// The layout follows docs/interop/qcow2.txt in QEMU with small clusters
/// (512 B or 1 KiB), so each L2 table maps `n = clusterSize / 8` guest clusters.
///
/// Host clusters: 0 header, 1 L1 table, 2 refcount table (empty), 3 L2 table
/// for guest clusters 0..<n, 4 L2 table for guest clusters 2n..<3n, 5-8 data,
/// then a raw-deflate compressed cluster starting 400 bytes into host cluster 9.
/// The file ends with that stream, so its last sector is cut short by EOF.
///
/// Guest clusters, chosen to hit every read path:
/// - 0: data `0xA1` (host 5).
/// - 1: unallocated.
/// - 2: v3 zero flag over host 6, which holds `0xEE` garbage that must not leak; v2 leaves it unallocated.
/// - 3: data `0xB2` (host 7).
/// - 4: compressed, a repeating `i * 7 + 3` byte pattern.
/// - n..<2n: L1 entry 1 is zero, so the whole L2 table is unallocated.
/// - 2n: data `0xC3` (host 8), cut short by the virtual size, which ends 300 bytes into it.
private struct TinyQCOW2 {
    var version: UInt32
    var clusterBits: UInt64
    var backingFileOffset: UInt64 = 0
    var cryptMethod: UInt32 = 0
    var incompatibleFeatures: UInt64 = 0
    var compressionType: UInt8 = 0
    var headerLength: UInt32?
    var virtualSizeOverride: UInt64?
    var l1SizeOverride: UInt32?
    var l1TableOffsetOverride: UInt64?
    var l2TableMisalignment: UInt64 = 0
    var dataMisalignment: UInt64 = 0
    var corruptDeflate = false

    var clusterSize: UInt64 { 1 << clusterBits }
    private var perL2: Int { Int(clusterSize / 8) }
    var virtualSize: UInt64 { UInt64(2 * perL2) * clusterSize + 300 }

    private var compressedPattern: Data {
        Data((0 ..< Int(clusterSize)).map { UInt8(truncatingIfNeeded: $0 * 7 + 3) })
    }

    var expectedRaw: Data {
        let size = Int(clusterSize)
        var data = Data(count: Int(virtualSize))
        data.replaceSubrange(0 ..< size, with: Data(repeating: 0xA1, count: size))
        data.replaceSubrange(3 * size ..< 4 * size, with: Data(repeating: 0xB2, count: size))
        data.replaceSubrange(4 * size ..< 5 * size, with: compressedPattern)
        data.replaceSubrange(2 * perL2 * size ..< Int(virtualSize), with: Data(repeating: 0xC3, count: 300))
        return data
    }

    func write(to url: URL) throws {
        let size = Int(clusterSize)
        let copied: UInt64 = 1 << 63
        let host = { (cluster: Int) in UInt64(cluster * size) }
        var image = Data(count: 9 * size)
        func put(_ value: some FixedWidthInteger, at offset: Int) {
            withUnsafeBytes(of: value.bigEndian) { image.replaceSubrange(offset ..< offset + $0.count, with: $0) }
        }
        func fill(cluster: Int, with byte: UInt8) {
            image.replaceSubrange(cluster * size ..< (cluster + 1) * size, with: Data(repeating: byte, count: size))
        }

        // Header.
        image.replaceSubrange(0 ..< 4, with: [0x51, 0x46, 0x49, 0xFB])
        put(version, at: 4)
        put(backingFileOffset, at: 8)
        put(UInt32(backingFileOffset == 0 ? 0 : 8), at: 16)
        put(UInt32(clusterBits), at: 20)
        put(virtualSizeOverride ?? virtualSize, at: 24)
        put(cryptMethod, at: 32)
        put(l1SizeOverride ?? 3, at: 36)
        put(l1TableOffsetOverride ?? host(1), at: 40)
        put(host(2), at: 48) // refcount_table_offset
        put(UInt32(1), at: 56) // refcount_table_clusters
        if version >= 3 {
            put(incompatibleFeatures, at: 72)
            put(UInt32(4), at: 96) // refcount_order
            put(headerLength ?? (compressionType == 0 ? 104 : 112), at: 100)
            image[104] = compressionType
        }

        // L1: entry 1 left zero (unallocated L2 table).
        put(host(3) | copied | l2TableMisalignment, at: size)
        put(host(4) | copied, at: size + 16)

        // Compressed stream for guest cluster 4, placed mid-sector at the end of the file.
        var stream = try Self.deflate(compressedPattern)
        if corruptDeflate { stream = Data(repeating: 0xFF, count: stream.count) }
        let compressedOffset = host(9) + 400
        let x = 62 - (clusterBits - 8)
        let extraSectors = (400 + UInt64(stream.count) + 511) / 512 - 1
        precondition(extraSectors < 1 << (clusterBits - 8), "compressed stream too large for the fixture")

        // L2 tables.
        let l2 = 3 * size
        put(host(5) | copied | dataMisalignment, at: l2)
        if version >= 3 { put(host(6) | copied | 1, at: l2 + 2 * 8) }
        put(host(7) | copied, at: l2 + 3 * 8)
        put(1 << 62 | extraSectors << x | compressedOffset, at: l2 + 4 * 8)
        put(host(8) | copied, at: 4 * size)

        fill(cluster: 5, with: 0xA1)
        fill(cluster: 6, with: 0xEE)
        fill(cluster: 7, with: 0xB2)
        fill(cluster: 8, with: 0xC3)
        image.append(Data(count: 400))
        image.append(stream)
        try image.write(to: url)
    }

    /// Raw deflate (RFC 1951), which is what qcow2's zlib compression stores.
    private static func deflate(_ data: Data) throws -> Data {
        var out = Data(count: data.count + 64)
        let count = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, dst.count,
                    src.bindMemory(to: UInt8.self).baseAddress!, src.count, nil, COMPRESSION_ZLIB
                )
            }
        }
        try #require(count > 0)
        return out.prefix(count)
    }
}
