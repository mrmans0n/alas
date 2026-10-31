import Compression
import Darwin
import Foundation

// The header layout, L1/L2 lookup, zero-cluster handling and compressed-cluster
// decoding are ported from lima-vm/go-qcow2reader (`image/qcow2/qcow2.go`,
// Apache-2.0, Copyright The Lima Authors), cut down to what an Ubuntu cloud
// image needs: no backing files, encryption, external data files, extended L2
// entries or zstd. Those throw instead of producing a wrong disk, and so does
// any header value that would overflow or allocate without bound.

public enum QCOW2ReaderError: Error, Equatable {
    case notQCOW2
    case unsupportedVersion(UInt32)
    case invalidClusterBits(UInt32)
    case invalidHeaderLength(UInt32)
    case encrypted
    case backingFile
    case unsupportedIncompatibleFeatures(UInt64)
    case unsupportedCompressionType(UInt8)
    case sizeTooLarge(UInt64)
    case l1TableTooLarge(UInt32)
    case l1TableTooSmall(UInt32)
    case invalidL1TableOffset(UInt64)
    case misalignedCluster(hostOffset: UInt64)
    case invalidCompressedCluster(guestOffset: UInt64)
    case truncated(at: UInt64)
    case cannotShrink(virtualSize: UInt64, requested: UInt64)
    case io(operation: String, errno: Int32)
}

/// Reads a qcow2 (version 2 or 3) image and writes it out as a sparse raw disk,
/// which is the only format Virtualization.framework boots.
public struct QCOW2Reader {
    public let virtualSize: UInt64

    private let url: URL
    private let version: UInt32
    private let clusterBits: UInt64
    private let l1Size: Int
    private let l1TableOffset: UInt64

    private static let magic: UInt32 = 0x5146_49FB // "QFI\xfb"
    private static let offsetMask: UInt64 = 0x00FF_FFFF_FFFF_FE00
    private static let compressedFlag: UInt64 = 1 << 62
    private static let zeroFlag: UInt64 = 1
    /// Guest sizes past 2^56 bytes can't be mapped by 56-bit host offsets anyway.
    private static let maxVirtualSize: UInt64 = 1 << 56
    private static let maxL1Bytes = 32 << 20

    /// The only incompatible feature tolerated (qcow2 v3). Bit 3 (a non-zlib
    /// compression type, i.e. zstd) is rejected.
    private static let dirtyBit: UInt64 = 1 << 0

    public init(url: URL) throws {
        self.url = url
        let fd = try Self.open(url.path, O_RDONLY)
        defer { close(fd) }
        let header = try Self.read(fd, count: 112, at: 0, allowShort: true)
        guard header.count >= 72, header.uint32(at: 0) == Self.magic else { throw QCOW2ReaderError.notQCOW2 }

        version = header.uint32(at: 4)
        guard version == 2 || version == 3 else { throw QCOW2ReaderError.unsupportedVersion(version) }
        guard header.uint64(at: 8) == 0 else { throw QCOW2ReaderError.backingFile }
        let bits = header.uint32(at: 20)
        guard (9 ... 21).contains(bits) else { throw QCOW2ReaderError.invalidClusterBits(bits) }
        clusterBits = UInt64(bits)
        virtualSize = header.uint64(at: 24)
        guard virtualSize <= Self.maxVirtualSize else { throw QCOW2ReaderError.sizeTooLarge(virtualSize) }
        guard header.uint32(at: 32) == 0 else { throw QCOW2ReaderError.encrypted }
        let l1Entries = header.uint32(at: 36)
        guard Int(l1Entries) * 8 <= Self.maxL1Bytes else { throw QCOW2ReaderError.l1TableTooLarge(l1Entries) }
        l1Size = Int(l1Entries)
        l1TableOffset = header.uint64(at: 40)

        if version == 3 {
            guard header.count >= 104 else { throw QCOW2ReaderError.truncated(at: UInt64(header.count)) }
            let headerLength = header.uint32(at: 100)
            guard headerLength >= 104 else { throw QCOW2ReaderError.invalidHeaderLength(headerLength) }
            let incompatible = header.uint64(at: 72)
            guard incompatible & ~Self.dirtyBit == 0 else {
                throw QCOW2ReaderError.unsupportedIncompatibleFeatures(incompatible)
            }
            if headerLength > 104 {
                guard header.count > 104 else { throw QCOW2ReaderError.truncated(at: UInt64(header.count)) }
                let compressionType = header[header.startIndex + 104]
                guard compressionType == 0 else { throw QCOW2ReaderError.unsupportedCompressionType(compressionType) }
            }
        }

        let clusterSize = UInt64(1) << clusterBits
        let bytesPerL1Entry = clusterSize * (clusterSize / 8) // at most 2^39
        let needed = (virtualSize + bytesPerL1Entry - 1) / bytesPerL1Entry
        guard UInt64(l1Size) >= needed else { throw QCOW2ReaderError.l1TableTooSmall(l1Entries) }
        let (l1End, overflow) = l1TableOffset.addingReportingOverflow(UInt64(l1Size * 8))
        guard !overflow, l1End <= UInt64(Int64.max), l1TableOffset & (clusterSize - 1) == 0 else {
            throw QCOW2ReaderError.invalidL1TableOffset(l1TableOffset)
        }
    }

    /// Writes the guest-visible bytes to `destination` as a sparse file, then
    /// extends it to `growTo` when given. Unallocated and zero clusters are left
    /// as holes. On failure the destination is removed, so a partial disk never
    /// passes for a converted one.
    public func convertToRaw(at destination: URL, growTo size: UInt64?) throws {
        let finalSize = size ?? virtualSize
        guard finalSize <= UInt64(Int64.max) else { throw QCOW2ReaderError.sizeTooLarge(finalSize) }
        guard finalSize >= virtualSize else {
            throw QCOW2ReaderError.cannotShrink(virtualSize: virtualSize, requested: finalSize)
        }
        let source = try Self.open(url.path, O_RDONLY)
        defer { close(source) }
        let output = try Self.open(destination.path, O_WRONLY | O_CREAT | O_TRUNC, mode: 0o644)
        do {
            defer { close(output) }
            guard ftruncate(output, off_t(finalSize)) == 0 else {
                throw QCOW2ReaderError.io(operation: "ftruncate", errno: errno)
            }
            try copyClusters(from: source, to: output)
            guard fsync(output) == 0 else { throw QCOW2ReaderError.io(operation: "fsync", errno: errno) }
        } catch {
            unlink(destination.path)
            throw error
        }
    }

    private func copyClusters(from source: Int32, to output: Int32) throws {
        let clusterSize = UInt64(1) << clusterBits
        let l2Entries = clusterSize / 8
        let l1 = try Self.read(source, count: l1Size * 8, at: l1TableOffset)
        for l1Index in 0 ..< l1Size {
            // l1Index < 2^22 and l2Entries * clusterSize <= 2^39, so this can't overflow.
            let guestOffset = UInt64(l1Index) * l2Entries * clusterSize
            guard guestOffset < virtualSize else { break }
            let l2Offset = l1.uint64(at: l1Index * 8) & Self.offsetMask
            guard l2Offset != 0 else { continue } // whole L2 table unallocated
            try checkAligned(l2Offset)
            let l2 = try Self.read(source, count: Int(clusterSize), at: l2Offset)
            for l2Index in 0 ..< Int(l2Entries) {
                let offset = guestOffset + UInt64(l2Index) * clusterSize
                guard offset < virtualSize else { break }
                let length = Int(min(clusterSize, virtualSize - offset))
                let entry = l2.uint64(at: l2Index * 8)
                let data: Data
                if entry & Self.compressedFlag != 0 {
                    data = try readCompressed(entry, guestOffset: offset, from: source).prefix(length)
                } else {
                    // Bit 0 is reserved in version 2 and only means "reads as zero" in version 3.
                    if version == 3, entry & Self.zeroFlag != 0 { continue }
                    let hostOffset = entry & Self.offsetMask
                    guard hostOffset != 0 else { continue } // unallocated, no backing file: zero
                    try checkAligned(hostOffset)
                    data = try Self.read(source, count: length, at: hostOffset)
                }
                // An allocated but all-zero cluster stays a hole too.
                guard data.withUnsafeBytes({ $0.contains { $0 != 0 } }) else { continue }
                try Self.write(output, data, at: offset)
            }
        }
    }

    /// A compressed L2 entry packs the byte offset of a raw-deflate stream in its
    /// low `62 - (clusterBits - 8)` bits and the number of extra 512-byte sectors
    /// the stream spans, counted from the offset's sector, above that.
    private func readCompressed(_ entry: UInt64, guestOffset: UInt64, from source: Int32) throws -> Data {
        let clusterSize = Int(1 << clusterBits)
        let shift = 62 - (clusterBits - 8)
        let hostOffset = entry & ((1 << shift) - 1)
        let sectors = ((entry >> shift) & ((1 << (clusterBits - 8)) - 1)) + 1
        let size = Int(sectors * 512 - (hostOffset & 511))
        // The last stream in the file may end before its last sector does.
        let compressed = try Self.read(source, count: size, at: hostOffset, allowShort: true)
        guard !compressed.isEmpty else { throw QCOW2ReaderError.invalidCompressedCluster(guestOffset: guestOffset) }
        var cluster = Data(count: clusterSize)
        let decoded = cluster.withUnsafeMutableBytes { dst in
            compressed.withUnsafeBytes { src in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, clusterSize,
                    src.bindMemory(to: UInt8.self).baseAddress!, src.count, nil, COMPRESSION_ZLIB
                )
            }
        }
        guard decoded == clusterSize else { throw QCOW2ReaderError.invalidCompressedCluster(guestOffset: guestOffset) }
        return cluster
    }

    private func checkAligned(_ hostOffset: UInt64) throws {
        guard hostOffset & ((1 << clusterBits) - 1) == 0 else {
            throw QCOW2ReaderError.misalignedCluster(hostOffset: hostOffset)
        }
    }

    private static func open(_ path: String, _ flags: Int32, mode: mode_t = 0) throws -> Int32 {
        let fd = Darwin.open(path, flags | O_CLOEXEC, mode)
        guard fd >= 0 else { throw QCOW2ReaderError.io(operation: "open", errno: errno) }
        return fd
    }

    private static func read(_ fd: Int32, count: Int, at offset: UInt64, allowShort: Bool = false) throws -> Data {
        var data = Data(count: count)
        var done = 0
        while done < count {
            let n = data.withUnsafeMutableBytes { buffer in
                pread(fd, buffer.baseAddress! + done, count - done, off_t(offset) + off_t(done))
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw QCOW2ReaderError.io(operation: "pread", errno: errno)
            }
            if n == 0 {
                guard allowShort else { throw QCOW2ReaderError.truncated(at: offset + UInt64(done)) }
                return data.prefix(done)
            }
            done += n
        }
        return data
    }

    private static func write(_ fd: Int32, _ data: Data, at offset: UInt64) throws {
        var done = 0
        while done < data.count {
            let n = data.withUnsafeBytes { buffer in
                pwrite(fd, buffer.baseAddress! + done, data.count - done, off_t(offset) + off_t(done))
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw QCOW2ReaderError.io(operation: "pwrite", errno: errno)
            }
            done += n
        }
    }
}

private extension Data {
    func uint32(at offset: Int) -> UInt32 {
        self[startIndex + offset ..< startIndex + offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    func uint64(at offset: Int) -> UInt64 {
        self[startIndex + offset ..< startIndex + offset + 8].reduce(0) { $0 << 8 | UInt64($1) }
    }
}
