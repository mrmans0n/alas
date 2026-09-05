import AVFoundation
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
}
