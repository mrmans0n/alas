import AlasRemoteKit
import AVFoundation
import CoreMedia
import Foundation
import Observation

@MainActor
@Observable
final class PeerDevicePlayback {
    enum Result: Equatable {
        case accepted
        case waiting
        case failed
    }

    let layer = AVSampleBufferDisplayLayer()
    var displayedSize: CGSize? { displayedFormat?.size }
    var displayedGeneration: UInt64? { displayedFormat?.generation }
    private var displayedFormat: VideoFormat?

    private struct VideoFormat: Equatable {
        let generation: UInt64
        let size: CGSize
    }

    @ObservationIgnored var onRecoveryNeeded: (() -> Void)?
    @ObservationIgnored private var currentFormat: VideoFormat?
    @ObservationIgnored private var codec: CMVideoFormatDescription?
    @ObservationIgnored private var waitingForKey = true
    @ObservationIgnored private var enqueuedFrame = false
    @ObservationIgnored private var flushing = false
    @ObservationIgnored private var pending: [(pts: UInt64, key: Bool, bytes: Data)] = []
    @ObservationIgnored private var pendingBytes = 0
    @ObservationIgnored private var draining = false

    private let notifications = Notifications()

    init() {
        layer.videoGravity = .resizeAspect
        notifications.observe(.AVSampleBufferDisplayLayerReadyForDisplayDidChange, object: layer) { [weak self] in
            self?.updateDisplayReadiness()
        }
        notifications.observe(AVSampleBufferVideoRenderer.didFailToDecodeNotification, object: layer.sampleBufferRenderer) { [weak self] in
            guard let self, enqueuedFrame, layer.sampleBufferRenderer.status == .failed else { return }
            onRecoveryNeeded?()
        }
    }

    isolated deinit {
        stopDraining()
    }

    func reset() {
        currentFormat = nil
        codec = nil
        resetDecoder()
    }

    func receive(_ packet: PeerDeviceVideoPacket) -> Result {
        switch packet {
        case .format(let generation, let width, let height):
            guard width > 0, height > 0 else { return .failed }
            let format = VideoFormat(generation: generation, size: CGSize(width: Int(width), height: Int(height)))
            if let currentFormat, currentFormat.generation >= generation {
                return currentFormat.generation == generation && currentFormat != format ? .failed : .waiting
            }
            reset()
            currentFormat = format
            return .accepted
        case .config(let generation, let bytes):
            guard let currentFormat, currentFormat.generation == generation else { return .waiting }
            guard let description = Self.formatDescription(bytes),
                  CMVideoFormatDescriptionGetPresentationDimensions(
                    description, usePixelAspectRatio: false, useCleanAperture: true
                  ) == currentFormat.size else { return .failed }
            resetDecoder()
            codec = description
            return .accepted
        case .frame(let generation, let pts, let keyFrame, let bytes):
            guard currentFormat?.generation == generation, let codec, !waitingForKey || keyFrame else { return .waiting }
            let renderer = layer.sampleBufferRenderer
            if !flushing && renderer.status == .failed { return .failed }
            if flushing || !pending.isEmpty || !renderer.isReadyForMoreMediaData {
                // An idle source can replay an entire GOP at once. Retain only a
                // short compressed backlog while the renderer catches up.
                guard pending.count < 32, bytes.count <= 512 * 1024 - pendingBytes else { return .failed }
                pending.append((pts, keyFrame, bytes))
                pendingBytes += bytes.count
                if !flushing { requestDrain() }
            } else if !enqueue(bytes, pts: pts, key: keyFrame, codec: codec) {
                return .failed
            }
            waitingForKey = false
            return .accepted
        }
    }

    private func resetDecoder() {
        displayedFormat = nil
        waitingForKey = true
        pending.removeAll(keepingCapacity: true)
        pendingBytes = 0
        stopDraining()
        guard enqueuedFrame else { return }
        enqueuedFrame = false
        flushing = true
        layer.sampleBufferRenderer.flush(removingDisplayedImage: true) { [weak self] in
            Task { @MainActor in self?.didFlush() }
        }
    }

    private func didFlush() {
        flushing = false
        drainPending()
    }

    private func requestDrain() {
        guard !draining else { return }
        draining = true
        layer.sampleBufferRenderer.requestMediaDataWhenReady(on: .main) { [weak self] in
            MainActor.assumeIsolated { self?.drainPending() }
        }
    }

    private func stopDraining() {
        guard draining else { return }
        draining = false
        layer.sampleBufferRenderer.stopRequestingMediaData()
    }

    private func drainPending() {
        guard !flushing, let codec else { return }
        let renderer = layer.sampleBufferRenderer
        while !pending.isEmpty, renderer.isReadyForMoreMediaData {
            let frame = pending.removeFirst()
            pendingBytes -= frame.bytes.count
            guard enqueue(frame.bytes, pts: frame.pts, key: frame.key, codec: codec) else {
                onRecoveryNeeded?()
                return
            }
        }
        if renderer.status == .failed {
            onRecoveryNeeded?()
        } else if pending.isEmpty {
            stopDraining()
        } else {
            requestDrain()
        }
    }

    private final class Notifications {
        private var tokens: [any NSObjectProtocol] = []

        func observe(_ name: Notification.Name, object: AnyObject, handler: @escaping @MainActor () -> Void) {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: nil) { _ in
                Task { @MainActor in handler() }
            })
        }

        deinit {
            for token in tokens { NotificationCenter.default.removeObserver(token) }
        }
    }

    private func updateDisplayReadiness() {
        displayedFormat = enqueuedFrame && !flushing && layer.isReadyForDisplay ? currentFormat : nil
    }

    private func enqueue(_ bytes: Data, pts: UInt64, key: Bool, codec: CMVideoFormatDescription) -> Bool {
        let renderer = layer.sampleBufferRenderer
        guard renderer.status != .failed, renderer.isReadyForMoreMediaData,
              let sample = Self.sampleBuffer(bytes, pts: pts, key: key, codec: codec) else { return false }
        enqueuedFrame = true
        renderer.enqueue(sample)
        return true
    }

    private static func formatDescription(_ bytes: Data) -> CMVideoFormatDescription? {
        bytes.withUnsafeBytes { raw in
            let raw = raw.bindMemory(to: UInt8.self)
            guard let base = raw.baseAddress else { return nil }
            let nals = nalRanges(raw)
            guard let sps = nals.first(where: { raw[$0.lowerBound] & 0x1F == 7 }),
                  let pps = nals.first(where: { raw[$0.lowerBound] & 0x1F == 8 }) else { return nil }
            var description: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: nil, parameterSetCount: 2,
                parameterSetPointers: [base + sps.lowerBound, base + pps.lowerBound],
                parameterSetSizes: [sps.count, pps.count], nalUnitHeaderLength: 4,
                formatDescriptionOut: &description
            )
            return status == noErr ? description : nil
        }
    }

    private static func sampleBuffer(_ bytes: Data, pts: UInt64, key: Bool, codec: CMVideoFormatDescription) -> CMSampleBuffer? {
        guard let time = Int64(exactly: pts) else { return nil }
        return bytes.withUnsafeBytes { raw in
            let raw = raw.bindMemory(to: UInt8.self)
            guard let base = raw.baseAddress else { return nil }
            let nals = nalRanges(raw)
            guard !nals.isEmpty, !key || nals.contains(where: { raw[$0.lowerBound] & 0x1F == 5 }) else { return nil }
            var size = nals.reduce(0) { $0 + 4 + $1.count }
            var block: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: nil, blockLength: size, blockAllocator: nil, customBlockSource: nil,
                offsetToData: 0, dataLength: size, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
            ) == noErr, let block else { return nil }
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                              totalLengthOut: nil, dataPointerOut: &pointer) == noErr,
                  let pointer else { return nil }
            // Write AVCC directly into CoreMedia's buffer, with no intermediate frame copy.
            var output = UnsafeMutableRawPointer(pointer)
            for nal in nals {
                withUnsafeBytes(of: UInt32(nal.count).bigEndian) { length in
                    output.copyMemory(from: length.baseAddress!, byteCount: 4)
                }
                output.advanced(by: 4).copyMemory(from: base + nal.lowerBound, byteCount: nal.count)
                output += 4 + nal.count
            }
            var timing = CMSampleTimingInfo(duration: .invalid,
                                            presentationTimeStamp: CMTime(value: time, timescale: 1_000_000),
                                            decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: codec,
                                            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
                  let sample,
                  let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
                  let attachment = CFArrayGetValueAtIndex(attachments, 0) else { return nil }
            let dictionary = unsafeBitCast(attachment, to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            if !key {
                CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
            return sample
        }
    }

    private static func nalRanges(_ bytes: UnsafeBufferPointer<UInt8>) -> [Range<Int>] {
        var nals: [Range<Int>] = []
        var start: Int?
        var index = 0
        while index + 2 < bytes.count {
            guard bytes[index] == 0, bytes[index + 1] == 0 else {
                index += 1
                continue
            }
            let length: Int
            if bytes[index + 2] == 1 {
                length = 3
            } else if bytes[index + 2] == 0, index + 3 < bytes.count, bytes[index + 3] == 1 {
                length = 4
            } else {
                index += 1
                continue
            }
            if let start, start < index { nals.append(start..<index) }
            index += length
            start = index
        }
        if let start, start < bytes.count { nals.append(start..<bytes.count) }
        return nals
    }
}
