import AlasCore
import CoreMedia
import Foundation
import VideoToolbox

/// Decodes scrcpy's H.264 into IOSurface-backed images the screen's layer
/// shows. Used from one queue at a time.
final class H264Decoder {
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    /// A config packet (SPS and PPS); a new one, after a rotation, replaces the session.
    func configure(_ config: Data) {
        guard let sets = H264AnnexB.parameterSets(config) else { return }
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
        var format: CMVideoFormatDescription?
        let status = sets.sps.withUnsafeBytes { sps in
            sets.pps.withUnsafeBytes { pps in
                let pointers = [
                    sps.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    pps.baseAddress!.assumingMemoryBound(to: UInt8.self),
                ]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: [sets.sps.count, sets.pps.count], nalUnitHeaderLength: 4,
                    formatDescriptionOut: &format
                )
            }
        }
        guard status == noErr, let format else { return }
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        ]
        var session: VTDecompressionSession?
        guard VTDecompressionSessionCreate(
            allocator: nil, formatDescription: format, decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary, outputCallback: nil, decompressionSessionOut: &session
        ) == noErr else { return }
        self.format = format
        self.session = session
    }

    /// The image for one frame's Annex B payload; nil before a config, or when it doesn't decode.
    func decode(_ frame: Data) -> CVPixelBuffer? {
        guard let format, let session else { return nil }
        let avcc = H264AnnexB.avcc(frame)
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: avcc.count, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &block
        ) == noErr, let block else { return nil }
        let copied = avcc.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = avcc.count
        guard CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0,
            sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample
        ) == noErr, let sample else { return nil }
        let output = DecodedImage()
        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            if status == noErr { output.image = image }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        return output.image
    }
}

/// The decoder's output handler is `@Sendable`; this carries its image out.
private final class DecodedImage: @unchecked Sendable {
    var image: CVPixelBuffer?
}
