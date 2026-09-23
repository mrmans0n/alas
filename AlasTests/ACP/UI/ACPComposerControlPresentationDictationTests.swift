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

@Suite("ACP composer compact controls")
struct ACPComposerOverflowItemsTests {
    @Test("full-access mode retains its warning tint in compact controls")
    func fullAccessWarns() {
        let spec = ChipSpec(source: .mode, options: [
            .init(id: "safe", name: "Safe", description: nil, kind: .standard),
            .init(id: "full", name: "Full access", description: nil, kind: .fullAccess),
        ], currentId: "full")

        #expect(ACPComposerControlPresentation.modeUsesWarningTint(spec))
        #expect(!ACPComposerControlPresentation.modeUsesWarningTint(
            ChipSpec(source: .mode, options: spec.options, currentId: "safe")
        ))
    }

    @Test("compact menu keeps every available session setting in a stable order")
    func allSettingsRemainAvailable() {
        let items = ACPComposerOverflowItem.items(
            hasMode: true,
            hasThinking: true,
            hasFastMode: true,
            parameterIDs: ["context-window", "temperature"],
            booleanIDs: ["sandbox"],
            hasProvider: true,
            hasAuthentication: true
        )

        #expect(items == [
            .mode,
            .thinking,
            .fastMode,
            .autoRun,
            .parameter("context-window"),
            .parameter("temperature"),
            .boolean("sandbox"),
            .provider,
            .authentication,
        ])
    }

    @Test("unavailable controls do not leave empty menu rows")
    func absentSettingsAreOmitted() {
        let items = ACPComposerOverflowItem.items(
            hasMode: false,
            hasThinking: false,
            hasFastMode: false,
            parameterIDs: [],
            booleanIDs: [],
            hasProvider: false,
            hasAuthentication: false
        )

        #expect(items == [.autoRun])
    }
}
