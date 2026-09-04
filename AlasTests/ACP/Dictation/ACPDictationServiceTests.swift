import Testing
@testable import Alas

@MainActor
private final class FakeDictationEngine: ACPDictationEngine {
    var isAvailable: Bool
    var installed: [String]
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var lastPreferredLocale: String?
    private var callbacks: ACPDictationCallbacks?

    init(isAvailable: Bool = true, installed: [String] = ["en_US"]) {
        self.isAvailable = isAvailable
        self.installed = installed
    }

    func installedLocaleIdentifiers() async -> [String] { installed }

    func start(preferredLocaleIdentifier: String?, callbacks: ACPDictationCallbacks) {
        startCallCount += 1
        lastPreferredLocale = preferredLocaleIdentifier
        self.callbacks = callbacks
    }

    // Deliberately keeps `callbacks` after stopping: the real engine's
    // async setup can fire a callback late, so holding onto them lets the
    // tests exercise the service's own state guards rather than a
    // convenience of this fake.
    func stop() {
        stopCallCount += 1
    }

    func simulateReady() { callbacks?.onReady() }
    func simulateResult(_ text: String, isFinal: Bool) { callbacks?.onResult(text, isFinal) }
    func simulateFailure(_ message: String) { callbacks?.onFailure(message) }
    func simulateSilence(deviceName: String?) { callbacks?.onSilence(deviceName) }
}

@MainActor
@Suite("ACP dictation service state machine")
struct ACPDictationServiceTests {
    @Test("starts idle when the engine is available")
    func startsIdleWhenAvailable() {
        let service = ACPDictationService(engine: FakeDictationEngine(isAvailable: true))
        #expect(service.state == .idle)
    }

    @Test("starts unavailable when the engine reports no support")
    func startsUnavailableWhenUnsupported() {
        let service = ACPDictationService(engine: FakeDictationEngine(isAvailable: false))
        #expect(service.state == .unavailable)
    }

    @Test("toggling from idle asks the engine to start and enters preparing")
    func toggleFromIdleStartsEngine() {
        let engine = FakeDictationEngine()
        let service = ACPDictationService(engine: engine)

        service.toggle()

        #expect(engine.startCallCount == 1)
        #expect(service.state == .preparing)
    }

    @Test("engine readiness moves preparing to listening")
    func engineReadinessEntersListening() {
        let engine = FakeDictationEngine()
        let service = ACPDictationService(engine: engine)

        service.toggle()
        engine.simulateReady()

        #expect(service.state == .listening)
    }

    @Test("toggling while listening stops the engine, returns to idle, and notifies onStop")
    func toggleWhileListeningStops() {
        let engine = FakeDictationEngine()
        let service = ACPDictationService(engine: engine)
        var stopNotified = false
        service.onStop = { stopNotified = true }

        service.toggle()
        engine.simulateReady()
        service.toggle()

        #expect(engine.stopCallCount == 1)
        #expect(service.state == .idle)
        #expect(stopNotified)
    }

    @Test("engine failure while preparing surfaces the message and notifies onStop")
    func engineFailureSurfacesMessage() {
        let engine = FakeDictationEngine()
        let service = ACPDictationService(engine: engine)
        var stopNotified = false
        service.onStop = { stopNotified = true }

        service.toggle()
        engine.simulateFailure("No microphone access")

        #expect(service.state == .failed("No microphone access"))
        #expect(stopNotified)
    }

    @Test("toggling from a failed state retries")
    func toggleFromFailedRetries() {
        let engine = FakeDictationEngine()
        let service = ACPDictationService(engine: engine)

        service.toggle()
        engine.simulateFailure("boom")
        service.toggle()

        #expect(engine.startCallCount == 2)
        #expect(service.state == .preparing)
    }

    @Test("results while listening forward to onTranscriptUpdate")
    func resultsForwardToTranscriptUpdate() {
        let engine = FakeDictationEngine()
        let service = ACPDictationService(engine: engine)
        var received: [(String, Bool)] = []
        service.onTranscriptUpdate = { received.append(($0, $1)) }

        service.toggle()
        engine.simulateReady()
        engine.simulateResult("hello", isFinal: false)
        engine.simulateResult("hello world", isFinal: true)

        #expect(received.count == 2)
        #expect(received[0] == ("hello", false))
        #expect(received[1] == ("hello world", true))
    }

    @Test("toggling while unavailable does nothing")
    func toggleWhileUnavailableDoesNothing() {
        let engine = FakeDictationEngine(isAvailable: false)
        let service = ACPDictationService(engine: engine)

        service.toggle()

        #expect(engine.startCallCount == 0)
        #expect(service.state == .unavailable)
    }

    @Test("starting again while already preparing is a no-op")
    func startWhileAlreadyPreparingIsNoOp() {
        let engine = FakeDictationEngine()
        let service = ACPDictationService(engine: engine)

        service.start()
        service.start()

        #expect(engine.startCallCount == 1)
    }

    @Test("stopping while idle is a no-op")
    func stopWhileIdleIsNoOp() {
        let engine = FakeDictationEngine()
        let service = ACPDictationService(engine: engine)
        var stopNotified = false
        service.onStop = { stopNotified = true }

        service.stop()

        #expect(engine.stopCallCount == 0)
        #expect(!stopNotified)
    }

    // MARK: - Preferred locale

    @Test("the chosen locale is handed to the engine on start")
    func preferredLocaleReachesEngine() {
        let engine = FakeDictationEngine()
        let service = ACPDictationService(engine: engine)
        service.preferredLocaleIdentifier = "es_ES"

        service.start()

        #expect(engine.lastPreferredLocale == "es_ES")
    }

    @Test("an empty locale preference reaches the engine as nil, meaning automatic")
    func emptyLocalePreferenceBecomesNil() {
        let engine = FakeDictationEngine()
        let service = ACPDictationService(engine: engine)
        service.preferredLocaleIdentifier = ""

        service.start()

        #expect(engine.startCallCount == 1)
        #expect(engine.lastPreferredLocale == nil)
    }

    // MARK: - Silence notices

    @Test("a silence report while listening names the offending input device")
    func silenceNoticeNamesDevice() {
        let engine = FakeDictationEngine()
        let service = ACPDictationService(engine: engine)
        var notices: [String] = []
        service.onNotice = { notices.append($0) }

        service.toggle()
        engine.simulateReady()
        engine.simulateSilence(deviceName: "Virtual Desktop Mic")

        #expect(notices == ["No audio from “Virtual Desktop Mic”. Check Sound settings."])
    }

    @Test("a silence report without a device name still explains the problem")
    func silenceNoticeWithoutDeviceName() {
        let engine = FakeDictationEngine()
        let service = ACPDictationService(engine: engine)
        var notices: [String] = []
        service.onNotice = { notices.append($0) }

        service.toggle()
        engine.simulateReady()
        engine.simulateSilence(deviceName: nil)

        #expect(notices == ["No audio from the microphone. Check Sound settings."])
    }

    @Test("a silence report that lands after stopping is ignored")
    func silenceNoticeAfterStopIsIgnored() {
        let engine = FakeDictationEngine()
        let service = ACPDictationService(engine: engine)
        var notices: [String] = []
        service.onNotice = { notices.append($0) }

        service.toggle()
        engine.simulateReady()
        service.stop()
        engine.simulateSilence(deviceName: "Virtual Desktop Mic")

        #expect(notices.isEmpty)
    }
}
