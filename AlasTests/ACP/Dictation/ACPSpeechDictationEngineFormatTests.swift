@preconcurrency import AVFoundation
import Foundation
import Speech
import Testing
@testable import Alas

@Suite("ACP speech dictation hardware format validation")
struct ACPSpeechDictationEngineFormatTests {
    @Test("a normal two-channel 48kHz format is usable")
    func normalFormatIsUsable() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        #expect(ACPSpeechDictationEngine.isUsableInputFormat(format))
    }

    @Test("a zero sample rate format is unusable, as reported with no input device")
    func zeroSampleRateIsUnusable() {
        let format = AVAudioFormat()
        #expect(!ACPSpeechDictationEngine.isUsableInputFormat(format))
    }

    @available(macOS 26.0, *)
    @MainActor
    @Test("the audio tap accepts buffers from CoreAudio's realtime queue")
    func audioTapAcceptsRealtimeBuffers() async {
        await #expect(processExitsWith: .success) {
            try await MainActor.run {
                let engine = AVAudioEngine()
                let sourceFormat = AVAudioFormat(
                    standardFormatWithSampleRate: 48_000,
                    channels: 1
                )!
                let source = AVAudioSourceNode(format: sourceFormat) {
                    @Sendable _, _, _, audioBufferList in
                    for audioBuffer in UnsafeMutableAudioBufferListPointer(audioBufferList) {
                        audioBuffer.mData?.initializeMemory(
                            as: UInt8.self,
                            repeating: 0,
                            count: Int(audioBuffer.mDataByteSize)
                        )
                    }
                    return noErr
                }
                engine.attach(source)
                engine.connect(source, to: engine.mainMixerNode, format: sourceFormat)

                let tapFormat = engine.mainMixerNode.outputFormat(forBus: 0)
                let converter = AVAudioConverter(from: tapFormat, to: tapFormat)!
                let (_, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
                let tap = ACPDictationAudioTap(
                    converter: converter,
                    outputFormat: tapFormat,
                    continuation: continuation
                )
                tap.install(
                    on: engine.mainMixerNode,
                    bus: 0,
                    bufferSize: 256,
                    format: nil
                )
                defer {
                    engine.mainMixerNode.removeTap(onBus: 0)
                    engine.stop()
                }

                engine.prepare()
                try engine.start()
                let deadline = Date(timeIntervalSinceNow: 2)
                while tap.stats.buffers == 0, Date() < deadline {
                    _ = RunLoop.current.run(
                        mode: .default,
                        before: min(Date(timeIntervalSinceNow: 0.01), deadline)
                    )
                }
                guard tap.stats.buffers > 0 else {
                    throw AudioTapTestError.bufferWasNotProcessed
                }
            }
        }
    }
}

private enum AudioTapTestError: Error {
    case bufferWasNotProcessed
}
