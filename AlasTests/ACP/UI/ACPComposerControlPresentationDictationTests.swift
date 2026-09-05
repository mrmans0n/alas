import Testing
@testable import Alas

@Suite("ACP composer mic button presentation")
struct ACPComposerControlPresentationDictationTests {
    @Test("icon reflects listening vs every other state")
    func micIconReflectsState() {
        #expect(ACPComposerControlPresentation.micIconName(for: .idle) == "mic")
        #expect(ACPComposerControlPresentation.micIconName(for: .preparing) == "mic")
        #expect(ACPComposerControlPresentation.micIconName(for: .listening) == "mic.fill")
        #expect(ACPComposerControlPresentation.micIconName(for: .failed("boom")) == "mic")
    }

    @Test("help text is state-specific")
    func micHelpTextIsStateSpecific() {
        #expect(ACPComposerControlPresentation.micHelp(for: .idle) == "Dictate into the composer")
        #expect(ACPComposerControlPresentation.micHelp(for: .preparing) == "Preparing dictation…")
        #expect(ACPComposerControlPresentation.micHelp(for: .listening) == "Listening — click to stop")
        #expect(ACPComposerControlPresentation.micHelp(for: .failed("No microphone access")) == "No microphone access")
        #expect(ACPComposerControlPresentation.micHelp(for: .unavailable) == "Dictation unavailable")
    }
}
