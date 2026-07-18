import Foundation
import Combine

/// Reference-typed text buffer shared between an `ACPMessage` value and
/// the SwiftUI row rendering it. Appending streaming chunks mutates one
/// String in place (amortized O(1)) instead of rebuilding the enclosing
/// enum case + reassigning the @Published transcript array on every
/// chunk (which over the lifetime of a message is O(n²) in chars).
///
/// Equality is by reference identity: two `.agent(id, buf)` values that
/// share the same buffer compare equal even as the text grows, so the
/// transcript-array diff doesn't fire on streaming. The inner row view
/// observes the buffer directly via @ObservedObject and re-renders
/// when the buffer publishes.
///
/// `value` is NOT `@Published`: the string mutates synchronously on every
/// `append` (so any reader sees the latest text immediately), but the
/// SwiftUI-facing `objectWillChange` publish is throttled to display rate
/// via `ACPTranscript.streamingTickAction`. Without this, a fast agent
/// response forces one full agent-row re-render — which re-runs
/// `ACPMarkdownBlockCache.update` + `ACPMarkdownText.parse(tail)` — per
/// streaming chunk (potentially hundreds/sec). Mirrors the `streamingTick`
/// throttle from #823, which coalesces whole-list invalidation but does
/// not cover this per-row buffer publish. A trailing-edge drain guarantees
/// the final chunk of a burst still renders within one throttle interval.
@MainActor
final class StreamingText: ObservableObject {
    private(set) var value: String
    private(set) var utf8Length: Int
    private(set) var revision: UInt64 = 0
    private(set) var lastAppendedSuffix: String?

    /// Wall-clock time (`ProcessInfo.systemUptime`) of the last publish.
    private var lastPublish: TimeInterval = 0
    /// Trailing-edge publish scheduled when a chunk arrives inside the
    /// throttle window; guarantees the last chunk of a burst renders.
    private var drainTask: Task<Void, Never>?

    #if DEBUG
    private(set) var publishCountForTests = 0
    #endif

    init(_ initial: String = "") {
        self.value = initial
        self.utf8Length = initial.utf8.count
    }

    deinit {
        drainTask?.cancel()
    }

    func append(_ s: String) {
        value.append(s)
        utf8Length += s.utf8.count
        revision &+= 1
        lastAppendedSuffix = s
        scheduleThrottledPublish()
    }

    private func scheduleThrottledPublish() {
        let now = ProcessInfo.processInfo.systemUptime
        switch ACPTranscript.streamingTickAction(
            elapsedSincePublish: now - lastPublish,
            hasPendingDrain: drainTask != nil
        ) {
        case .publishNow:
            publish(at: now)
        case .scheduleDrain(let delay):
            drainTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.drainTask = nil
                self.publish(at: ProcessInfo.processInfo.systemUptime)
            }
        case .drop:
            break
        }
    }

    private func publish(at time: TimeInterval) {
        lastPublish = time
        #if DEBUG
        publishCountForTests += 1
        #endif
        objectWillChange.send()
    }
}

extension StreamingText: Equatable {
    nonisolated static func == (lhs: StreamingText, rhs: StreamingText) -> Bool { lhs === rhs }
}
