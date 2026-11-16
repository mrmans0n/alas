import AlasCore
import Foundation
import Observation

/// Records what the user does on a device's screen as a flow: taps named by
/// the element under them in the latest snapshot, typing, keys and swipes.
/// The snapshot is read again a moment after each action, once the screen moved.
@MainActor
@Observable
final class DeviceFlowRecorder {
    private struct Recording {
        /// Tells this recording from a later one on the same device, across awaits.
        let token = UUID()
        let backend: any DeviceBackend
        var flow: DeviceFlow
        var snapshot: DeviceSnapshot?
        /// Characters typed since the last step, sent as one `inputText`.
        var typed = ""
        var refresh: Task<Void, Never>?
        /// Scroll deltas since the last step, sent as one swipe.
        var scrolled = (dx: 0.0, dy: 0.0)
        var scrollEnd: Task<Void, Never>?

        /// Typing and scrolling still pending, as steps, before the next one. Only one
        /// of the two is ever pending: each flushes the other when it starts.
        mutating func flush() {
            flushTyping()
            flushScroll()
        }

        mutating func flushTyping() {
            guard !typed.isEmpty else { return }
            flow.steps.append(.inputText(typed))
            typed = ""
        }

        mutating func flushScroll() {
            scrollEnd?.cancel()
            if let direction = DeviceFlow.scrollDirection(dx: scrolled.dx, dy: scrolled.dy) {
                flow.steps.append(.swipe(direction))
            }
            scrolled = (0, 0)
        }
    }

    private var recordings: [String: Recording] = [:]
    @ObservationIgnored private let settleDelay: Duration

    init(settleDelay: Duration = .seconds(1)) {
        self.settleDelay = settleDelay
    }

    func isRecording(_ udid: String) -> Bool {
        recordings[udid] != nil
    }

    /// Starts with the app in front, which the flow launches first, and the screen as it is.
    func start(udid: String, backend: any DeviceBackend) async {
        let recording = Recording(backend: backend, flow: DeviceFlow(appID: nil, steps: []))
        recordings[udid] = recording
        let app = await backend.frontApp(udid)
        let snapshot = try? await backend.snapshot(udid, generation: 0)
        // Stopped, and maybe started again, meanwhile.
        guard recordings[udid]?.token == recording.token else { return }
        if let app, recordings[udid]?.flow.steps.isEmpty == true {
            recordings[udid]?.flow.appID = app
            recordings[udid]?.flow.steps = [.launchApp(nil)]
        }
        if recordings[udid]?.snapshot == nil { recordings[udid]?.snapshot = snapshot }
    }

    /// A click or drag from `from` to `to`, upright 0…1 points.
    func gesture(_ udid: String, from: DeviceScreenPoint, to: DeviceScreenPoint) {
        guard var recording = recordings[udid] else { return }
        recording.flush()
        if let direction = DeviceFlow.swipeDirection(from: from, to: to) {
            recording.flow.steps.append(.swipe(direction))
        } else {
            let element = recording.snapshot.flatMap { DeviceFlow.element(at: from, in: $0) }
            recording.flow.steps.append(.tapOn(DeviceFlow.selector(for: element, at: from)))
        }
        recordings[udid] = recording
        refreshSnapshot(udid)
    }

    /// Characters the user typed: Return is the Enter key, Delete takes the last one back.
    func typed(_ udid: String, _ characters: String) {
        guard var recording = recordings[udid] else { return }
        for character in characters {
            switch character {
            case "\r", "\n":
                recording.flush()
                recording.flow.steps.append(.pressKey(.enter))
            case "\u{7F}", "\u{8}":
                if !recording.typed.isEmpty { recording.typed.removeLast() }
            default:
                // Arrow and function keys arrive as private-use characters.
                let printable = character.unicodeScalars.allSatisfy {
                    !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value)
                }
                if printable {
                    recording.flushScroll()
                    recording.typed.append(character)
                }
            }
        }
        recordings[udid] = recording
        // Typing can change the screen too, as search suggestions do.
        refreshSnapshot(udid)
    }

    /// A wheel or trackpad scroll's deltas; one scroll's events add up to one swipe.
    func scrolled(_ udid: String, dx: Double, dy: Double) {
        guard recordings[udid] != nil else { return }
        recordings[udid]?.flushTyping()
        recordings[udid]?.scrolled.dx += dx
        recordings[udid]?.scrolled.dy += dy
        recordings[udid]?.scrollEnd?.cancel()
        let token = recordings[udid]?.token
        recordings[udid]?.scrollEnd = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self, self.recordings[udid]?.token == token else { return }
            self.recordings[udid]?.flush()
            self.refreshSnapshot(udid)
        }
    }

    func pressed(_ udid: String, _ key: DeviceFlow.Key) {
        guard var recording = recordings[udid] else { return }
        recording.flush()
        recording.flow.steps.append(.pressKey(key))
        recordings[udid] = recording
        refreshSnapshot(udid)
    }

    /// The recorded flow; nil when none was recording.
    func stop(_ udid: String) -> DeviceFlow? {
        guard var recording = recordings.removeValue(forKey: udid) else { return nil }
        recording.refresh?.cancel()
        recording.flush()
        return recording.flow
    }

    private func refreshSnapshot(_ udid: String) {
        recordings[udid]?.refresh?.cancel()
        guard let backend = recordings[udid]?.backend else { return }
        let delay = settleDelay
        let token = recordings[udid]?.token
        recordings[udid]?.refresh = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let snapshot = try? await backend.snapshot(udid, generation: 0),
                  !Task.isCancelled, self?.recordings[udid]?.token == token else { return }
            self?.recordings[udid]?.snapshot = snapshot
        }
    }
}
