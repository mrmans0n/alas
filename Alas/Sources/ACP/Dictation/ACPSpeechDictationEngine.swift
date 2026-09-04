@preconcurrency import AVFoundation
import Foundation
import Speech
import os

/// Counters updated on CoreAudio's realtime thread and reported through
/// the log; never read for control flow.
private final class ACPDictationTapStats: @unchecked Sendable {
    var buffers = 0
    var peak: Float = 0
    var lastConvertedFrames: AVAudioFrameCount = 0
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
        let wrapped = ACPDictationCallbacks(
            onReady: callbacks.onReady,
            onResult: callbacks.onResult,
            onFailure: { [weak self, weak session] message in
                // A failure that resolves after a newer session has already
                // replaced this one (e.g. this session was mid-permission-
                // prompt or mid-download when stopped, and a fresh one was
                // started before the throw actually landed) must not clear
                // that newer session or report its own failure as the
                // current state.
                guard let self, let session, self.session as? Session === session else { return }
                self.session = nil
                callbacks.onFailure(message)
            },
            onSilence: callbacks.onSilence
        )
        Task {
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
        /// Set by `stop()`. Checked after every `await` in `start()` so a
        /// stop requested mid-setup (permission prompts, model download)
        /// aborts cleanly instead of spinning up an engine nobody wants
        /// anymore.
        private var stopped = false
        nonisolated private static let logger = Logger(subsystem: "io.nlopez.alas", category: "dictation")

        func run(preferredLocaleIdentifier: String?, callbacks: ACPDictationCallbacks) async {
            do {
                try await start(preferredLocaleIdentifier: preferredLocaleIdentifier, callbacks: callbacks)
            } catch {
                stop()
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
                stats.buffers += 1
                if let channel = buffer.floatChannelData?[0] {
                    for i in 0..<Int(buffer.frameLength) { stats.peak = max(stats.peak, abs(channel[i])) }
                }
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
            audioEngine?.inputNode.removeTap(onBus: 0)
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
