@preconcurrency import AVFoundation
import Foundation
import Speech
import os

/// Counters updated on CoreAudio's realtime tap thread. `lastConvertedFrames`
/// is only ever read from that same thread (a per-buffer log line), so it's
/// a plain property. `buffers` and `peak` are different: the main-actor
/// silence watchdog reads both — in its own log line and in the actual
/// silence check — so every access to either goes through `os_unfair_lock`,
/// taken once per buffer via `recordBuffer(peak:)` rather than once per
/// field. `os_unfair_lock` is an uncontended, non-blocking-in-practice lock
/// safe to take from a realtime thread, unlike a queue or `NSLock`. Without
/// it these would be real data races (the compiler's `@unchecked Sendable`
/// only suppresses the warning; it doesn't provide synchronization), and
/// the watchdog could read stale values and report silence over live audio.
private final class ACPDictationTapStats: @unchecked Sendable {
    var lastConvertedFrames: AVAudioFrameCount = 0

    private var lock = os_unfair_lock_s()
    private var _buffers = 0
    private var _peak: Float = 0

    func recordBuffer(peak: Float) {
        os_unfair_lock_lock(&lock)
        _buffers += 1
        _peak = max(_peak, peak)
        os_unfair_lock_unlock(&lock)
    }

    var buffers: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _buffers
    }

    var peak: Float {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _peak
    }
}

/// Concrete `ACPDictationEngine` backed by macOS 26's on-device
/// `SpeechAnalyzer` / `DictationTranscriber` pipeline: captures microphone
/// audio via `AVAudioEngine`, converts it to the transcriber's preferred
/// format, and streams results back through the `ACPDictationEngine`
/// callbacks.
///
/// Below macOS 26, `isAvailable` is false and `ACPDictationService` never
/// calls `start` (the composer hides the mic button entirely in that
/// case), but `start` still reports failure defensively if it ever is.
///
/// All macOS-26-only state lives in the nested `Session` type so this
/// class itself stays instantiable on every OS version the app supports.
@MainActor
final class ACPSpeechDictationEngine: ACPDictationEngine {
    var isAvailable: Bool {
        if #available(macOS 26.0, *) {
            return true
        }
        return false
    }

    /// Type-erased because `Session` only exists on macOS 26+.
    private var session: Any?

    func installedLocaleIdentifiers() async -> [String] {
        guard #available(macOS 26.0, *) else { return [] }
        return await DictationTranscriber.installedLocales.map(\.identifier)
    }

    /// True when `format` is a real, capturable hardware format. A Mac with
    /// no active input device — no built-in mic, external input
    /// disconnected mid-session — reports a degenerate (zero-rate or
    /// zero-channel) format on the input node. Installing a tap with that
    /// format hits an `AVAudioEngine` precondition and crashes the process
    /// rather than throwing a catchable error, so callers must check this
    /// first and fail through `onFailure` instead.
    nonisolated static func isUsableInputFormat(_ format: AVAudioFormat) -> Bool {
        format.sampleRate > 0 && format.channelCount > 0
    }

    /// Every language the engine can transcribe, including ones whose
    /// assets still need downloading. Used by Settings, which offers the
    /// full list; the mic menu sticks to installed ones.
    static func supportedLocaleIdentifiers() async -> [String] {
        guard #available(macOS 26.0, *) else { return [] }
        return await DictationTranscriber.supportedLocales.map(\.identifier)
    }

    func start(preferredLocaleIdentifier: String?, callbacks: ACPDictationCallbacks) {
        guard #available(macOS 26.0, *) else {
            callbacks.onFailure("Dictation requires macOS 26 or later.")
            return
        }
        let session = Session()
        self.session = session
        // Every callback must check it's still hearing from the session
        // `self.session` currently points to. A session can keep running
        // asynchronously (mid-permission-prompt, mid-download, or a
        // straggling result) after being superseded by a fresh one — e.g.
        // stop() followed immediately by start() — and an unscoped callback
        // would let the stale session mark the new one ready, splice its
        // transcript into the new one's, or report its own failure as the
        // current state.
        //
        // All four closures capture `self` and `session` weakly: they're
        // held by `session` for as long as it runs, so a strong capture of
        // either would keep this engine (and every session it ever
        // started) alive until the app quits.
        let wrapped = ACPDictationCallbacks(
            onReady: { [weak self, weak session] in
                guard let self, let session, self.session as? Session === session else { return }
                callbacks.onReady()
            },
            onResult: { [weak self, weak session] text, isFinal in
                guard let self, let session, self.session as? Session === session else { return }
                callbacks.onResult(text, isFinal)
            },
            onFailure: { [weak self, weak session] message in
                guard let self, let session, self.session as? Session === session else { return }
                self.session = nil
                callbacks.onFailure(message)
            },
            onSilence: { [weak self, weak session] deviceName in
                guard let self, let session, self.session as? Session === session else { return }
                callbacks.onSilence(deviceName)
            }
        )
        session.runTask = Task {
            await session.run(preferredLocaleIdentifier: preferredLocaleIdentifier, callbacks: wrapped)
        }
    }

    func stop() {
        if #available(macOS 26.0, *), let session = session as? Session {
            session.stop()
        }
        session = nil
    }

    /// Locales to try, in order, when picking the transcriber's language:
    /// the app's effective locale first, then the user's preferred
    /// languages, then `en_US` as a last resort. Identifiers are
    /// normalized to underscore form and de-duplicated.
    ///
    /// `Locale.current` inside this (English-only) bundle is not the
    /// system locale — macOS combines the bundle's best-matching
    /// localization with the user's region, so a Spanish-system user gets
    /// `en_ES`, which the transcriber rejects outright. Each candidate is
    /// therefore resolved through `supportedLocale(equivalentTo:)`
    /// (`en_ES` → `en_US`) rather than matched exactly.
    /// `explicit` is the user's chosen language, which leads the chain when
    /// set. It's a candidate rather than an override so an unsupported
    /// choice degrades to automatic detection instead of failing outright.
    nonisolated static func localeCandidates(
        explicit: String? = nil,
        current: Locale,
        preferredLanguages: [String]
    ) -> [Locale] {
        var seen = Set<String>()
        var result: [Locale] = []
        let leading = (explicit?.isEmpty == false) ? [explicit!] : []
        let raw = leading + [current.identifier] + preferredLanguages + ["en_US"]
        for identifier in raw {
            let normalized = identifier.replacingOccurrences(of: "-", with: "_")
            guard seen.insert(normalized).inserted else { continue }
            result.append(Locale(identifier: normalized))
        }
        return result
    }

    @available(macOS 26.0, *)
    @MainActor
    private final class Session {
        private var audioEngine: AVAudioEngine?
        private var analyzer: SpeechAnalyzer?
        private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
        private var resultsTask: Task<Void, Never>?
        private var silenceTask: Task<Void, Never>?
        /// The task running `run(preferredLocaleIdentifier:callbacks:)`,
        /// cancelled by `stop()` so a stop requested mid-setup doesn't
        /// leave, say, a speech-model download running unattended in the
        /// background after the user asked to cancel.
        var runTask: Task<Void, Never>?
        /// Set by `stop()`. Checked after every `await` in `start()` so a
        /// stop requested mid-setup (permission prompts, model download)
        /// aborts cleanly instead of spinning up an engine nobody wants
        /// anymore.
        private var stopped = false
        /// `removeTap(onBus:)` hits an `AVAudioNode` precondition (a crash,
        /// not a catchable error) if no tap was ever installed on that bus.
        /// `audioEngine` is assigned before the format/converter checks
        /// that can throw ahead of `installTap`, so `stop()` — reached via
        /// `run()`'s catch on exactly that throw — needs to know whether
        /// installation actually happened before it tries to remove one.
        private var tapInstalled = false
        nonisolated private static let logger = Logger(subsystem: "io.nlopez.alas", category: "dictation")

        func run(preferredLocaleIdentifier: String?, callbacks: ACPDictationCallbacks) async {
            do {
                try await start(preferredLocaleIdentifier: preferredLocaleIdentifier, callbacks: callbacks)
            } catch {
                // A stop-triggered cancellation surfaces here as a thrown
                // `CancellationError` (or any error a cancelled `await`
                // happened to raise) — `stopped` is already true by the
                // time it's caught, since `stop()` sets it before
                // cancelling this task. Reporting that as onFailure would
                // show a spurious error notice after a deliberate stop.
                let wasAlreadyStopped = stopped
                stop()
                guard !wasAlreadyStopped else { return }
                callbacks.onFailure(Self.userMessage(for: error))
            }
        }

        private func start(
            preferredLocaleIdentifier: String?,
            callbacks: ACPDictationCallbacks
        ) async throws {
            let onReady = callbacks.onReady
            let onResult = callbacks.onResult
            let onFailure = callbacks.onFailure
            guard await Self.requestMicrophoneAccess() else {
                throw DictationError.microphoneDenied
            }
            guard await Self.requestSpeechAuthorization() else {
                throw DictationError.speechDenied
            }
            Self.logger.info("auth ok: mic=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) speech=\(SFSpeechRecognizer.authorizationStatus().rawValue)")
            guard !stopped else { return }

            guard let locale = await Self.resolveLocale(explicit: preferredLocaleIdentifier) else {
                throw DictationError.localeUnsupported
            }
            Self.logger.info("locale resolved: \(locale.identifier)")
            let transcriber = DictationTranscriber(
                locale: locale,
                contentHints: [.shortForm],
                transcriptionOptions: [.punctuation],
                reportingOptions: [.volatileResults],
                attributeOptions: []
            )

            guard await AssetInventory.status(forModules: [transcriber]) != .unsupported else {
                throw DictationError.localeUnsupported
            }
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
            guard !stopped else { return }

            guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
            else {
                throw DictationError.noCompatibleAudioFormat
            }
            guard !stopped else { return }

            let analyzer = SpeechAnalyzer(modules: [transcriber])
            self.analyzer = analyzer

            let audioEngine = AVAudioEngine()
            self.audioEngine = audioEngine
            let inputFormat = audioEngine.inputNode.outputFormat(forBus: 0)
            guard ACPSpeechDictationEngine.isUsableInputFormat(inputFormat) else {
                throw DictationError.noInputDevice
            }
            guard let converter = AVAudioConverter(from: inputFormat, to: analyzerFormat) else {
                throw DictationError.noCompatibleAudioFormat
            }
            Self.logger.info("formats: input=\(inputFormat) analyzer=\(analyzerFormat)")

            let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
            inputContinuation = continuation

            // Runs on CoreAudio's realtime render thread, not the main
            // actor — `convert` is a `nonisolated` pure function and
            // `continuation.yield` is safe to call from any thread.
            let stats = ACPDictationTapStats()
            audioEngine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
                // A multichannel USB/aggregate input may carry the active
                // microphone on any channel, not just 0 — checking only
                // channel 0 would report silence (and eventually the false
                // "no audio" warning) while a working mic was plugged into
                // a different channel.
                var bufferPeak: Float = 0
                if let channelData = buffer.floatChannelData {
                    let frameCount = Int(buffer.frameLength)
                    for c in 0..<Int(buffer.format.channelCount) {
                        let channel = channelData[c]
                        for i in 0..<frameCount { bufferPeak = max(bufferPeak, abs(channel[i])) }
                    }
                }
                // One lock acquisition per buffer, not per sample or per
                // field — this runs on a realtime thread every ~85ms.
                stats.recordBuffer(peak: bufferPeak)
                guard let converted = Self.convert(buffer, using: converter, to: analyzerFormat) else {
                    Self.logger.error("convert returned nil for buffer \(stats.buffers)")
                    return
                }
                stats.lastConvertedFrames = converted.frameLength
                if stats.buffers % 50 == 0 {
                    Self.logger.info("tap: buffers=\(stats.buffers) peak=\(stats.peak) convertedFrames=\(stats.lastConvertedFrames)")
                }
                continuation.yield(AnalyzerInput(buffer: converted))
            }
            tapInstalled = true

            audioEngine.prepare()
            try audioEngine.start()
            guard !stopped else {
                stop()
                return
            }

            resultsTask = Task { [weak self] in
                do {
                    var count = 0
                    for try await result in transcriber.results {
                        count += 1
                        let text = String(result.text.characters)
                        Self.logger.info("result #\(count) final=\(result.isFinal) chars=\(text.count)")
                        onResult(text, result.isFinal)
                    }
                    Self.logger.info("results stream ended after \(count) results")
                } catch {
                    Self.logger.error("results stream threw: \(String(describing: error))")
                    self?.stop()
                    onFailure(Self.userMessage(for: error))
                }
            }

            try await analyzer.start(inputSequence: stream)
            Self.logger.info("analyzer started; engine running=\(audioEngine.isRunning)")
            startSilenceWatchdog(stats: stats, onSilence: callbacks.onSilence)
            onReady()
        }

        /// Amplitude at or below this counts as digital silence. Real
        /// microphones always carry some noise floor, so anything this
        /// quiet means no signal is reaching us at all.
        private static let silenceThreshold: Float = 1e-5
        /// How long to listen before concluding the input is dead. Long
        /// enough that a slow starter isn't nagged, short enough to save
        /// the user from talking into the void.
        private static let silenceGraceSeconds: UInt64 = 4

        /// Warns once if every sample in the opening seconds was silence.
        /// Deliberately does not stop dictation: the user may simply not
        /// have started talking yet, and a wrong guess shouldn't cost them
        /// their session.
        private func startSilenceWatchdog(
            stats: ACPDictationTapStats,
            onSilence: @escaping (String?) -> Void
        ) {
            silenceTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.silenceGraceSeconds * 1_000_000_000)
                guard let self, !Task.isCancelled, !self.stopped else { return }
                guard stats.peak <= Self.silenceThreshold else { return }
                let deviceName = AVCaptureDevice.default(for: .audio)?.localizedName
                Self.logger.error("silent input after \(Self.silenceGraceSeconds)s: device=\(deviceName ?? "unknown") buffers=\(stats.buffers)")
                onSilence(deviceName)
            }
        }

        /// Tears down the tap, engine, and analyzer immediately. Whatever
        /// transcript was already applied to the composer (the last
        /// volatile update) stays in place as plain, editable text — this
        /// does not wait for a trailing final result.
        func stop() {
            Self.logger.info("stop requested (engine running=\(self.audioEngine?.isRunning ?? false))")
            stopped = true
            // Cancels whatever `start()` is currently awaiting — permission
            // prompts, and notably `AssetInstallationRequest.downloadAndInstall()`,
            // which would otherwise keep fetching an unwanted speech model
            // in the background after the user asked to stop. The `guard
            // !stopped` checkpoints in `start()` only run on normal return
            // from an await; a cancelled await instead throws, which
            // `run()`'s catch handles.
            runTask?.cancel()
            runTask = nil
            if tapInstalled {
                audioEngine?.inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
            audioEngine?.stop()
            audioEngine = nil
            inputContinuation?.finish()
            inputContinuation = nil
            resultsTask?.cancel()
            resultsTask = nil
            silenceTask?.cancel()
            silenceTask = nil
            let analyzer = analyzer
            self.analyzer = nil
            Task { await analyzer?.cancelAndFinishNow() }
        }

        /// Converts one buffer through `converter` to `format`. Not
        /// actor-isolated: called directly from the audio tap's realtime
        /// thread, which cannot `await` a hop to the main actor.
        nonisolated private static func convert(
            _ buffer: AVAudioPCMBuffer,
            using converter: AVAudioConverter?,
            to format: AVAudioFormat
        ) -> AVAudioPCMBuffer? {
            guard let converter else { return nil }
            let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
            // The input block below runs synchronously, once, inline within
            // this call to `convert` (never concurrently) — `AVAudioConverter`
            // just types the block `@Sendable` because it COULD in principle
            // call back on another thread for other conversion shapes.
            nonisolated(unsafe) var suppliedInput = false
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                if suppliedInput {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                suppliedInput = true
                inputStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, conversionError == nil else { return nil }
            return output
        }

        /// First candidate from `localeCandidates` that the transcriber
        /// can serve, mapped to its exact supported form.
        private static func resolveLocale(explicit: String?) async -> Locale? {
            let candidates = ACPSpeechDictationEngine.localeCandidates(
                explicit: explicit,
                current: Locale.current,
                preferredLanguages: Locale.preferredLanguages
            )
            for candidate in candidates {
                if let match = await DictationTranscriber.supportedLocale(equivalentTo: candidate) {
                    return match
                }
            }
            return nil
        }

        private static func requestMicrophoneAccess() async -> Bool {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                return true
            case .notDetermined:
                return await withCheckedContinuation { continuation in
                    AVCaptureDevice.requestAccess(for: .audio) { granted in
                        continuation.resume(returning: granted)
                    }
                }
            case .denied, .restricted:
                return false
            @unknown default:
                return false
            }
        }

        private static func requestSpeechAuthorization() async -> Bool {
            if SFSpeechRecognizer.authorizationStatus() == .authorized {
                return true
            }
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        }

        private static func userMessage(for error: Error) -> String {
            (error as? DictationError)?.message ?? "Dictation failed to start."
        }

        private enum DictationError: Error {
            case microphoneDenied
            case speechDenied
            case localeUnsupported
            case noCompatibleAudioFormat
            case noInputDevice

            var message: String {
                switch self {
                case .microphoneDenied: return "Microphone access denied"
                case .speechDenied: return "Speech recognition access denied"
                case .localeUnsupported: return "Dictation isn't supported for this language"
                case .noCompatibleAudioFormat: return "No compatible audio format found"
                case .noInputDevice: return "No microphone is available"
                }
            }
        }
    }
}
