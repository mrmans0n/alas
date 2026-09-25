import Darwin
import Foundation
import Synchronization
import Testing
@testable import Alas

@Suite(.serialized)
struct NextPromptInferenceTests {
    @Test func repeatedLoadFailureRequiresExplicitRetry() async throws {
        let fixture = try LeaseFixture()
        let attempts = Mutex(0)
        let inference = NextPromptInference(acquireLease: { try fixture.acquire() }, load: { _ in
            attempts.withLock { $0 += 1 }
            throw POSIXError(.ENOMEM)
        })
        for _ in 0..<3 { _ = try? await inference.generate(request) }
        #expect(await inference.state == .retryRequired)
        #expect(attempts.withLock { $0 } == 2)
        #expect(fixture.canLockExclusively())
        await inference.retryAfterFailure()
        _ = try? await inference.generate(request)
        #expect(attempts.withLock { $0 } == 3)
    }

    @Test func unloadAndReplacementRetainLeaseUntilEvaluationDrains() async throws {
        let fixture = try LeaseFixture()
        let entered = Gate(), finish = Gate()
        let events = Mutex<[String]>([])
        let calls = Mutex(0)
        let inference = NextPromptInference(acquireLease: { try fixture.acquire() }, load: { _ in
            return { _ in
                let first = calls.withLock {
                    $0 += 1
                    return $0 == 1
                }
                if first {
                    events.withLock { $0.append("first started") }
                    await entered.open()
                    await finish.wait()
                    #expect(!fixture.canLockExclusively())
                    events.withLock { $0.append("first drained") }
                } else { events.withLock { $0.append("replacement started") } }
                return #"{"suggestion":"Show an example."}"#
            }
        })
        let first = Task { try await inference.generate(request) }
        await entered.wait()
        let stop = Task { await inference.cancelAndUnload() }
        try await eventually { await inference.state == .unloading }
        let replacement = Task { try await inference.generate(request) }
        #expect(!fixture.canLockExclusively())
        await finish.open()
        #expect(try await first.value == nil)
        await stop.value
        #expect(try await replacement.value == "Show an example.")
        #expect(events.withLock { $0 } == ["first started", "first drained", "replacement started"])
        await inference.cancelAndUnload()
        #expect(fixture.canLockExclusively())
    }

    @Test func deadlineIncludesColdLoadAndRejectsLateCompletion() async throws {
        let fixture = try LeaseFixture()
        let clock = ManualClock()
        let entered = Gate(), finish = Gate()
        let inference = NextPromptInference(acquireLease: { try fixture.acquire() }, load: { _ in
            await entered.open()
            await finish.wait()
            return { _ in #"{"suggestion":"Late candidate."}"# }
        }, clock: clock.clock)
        let first = Task { try await inference.generate(request) }
        await entered.wait()
        clock.advance(.seconds(15))
        try await eventually { await inference.state == .unloading }
        #expect(!fixture.canLockExclusively())
        await finish.open()
        #expect(try await first.value == nil)
        try await eventually { fixture.canLockExclusively() }
        try await eventually { await inference.state == .ready }
    }

    @Test func idleUnloadIsCancelledByNewRequest() async throws {
        let fixture = try LeaseFixture()
        let clock = ManualClock()
        let inference = NextPromptInference(acquireLease: { try fixture.acquire() }, load: { _ in
            return { _ in #"{"suggestion":"Show an example."}"# }
        }, clock: clock.clock)
        #expect(try await inference.generate(request) != nil)
        clock.advance(.seconds(59))
        #expect(try await inference.generate(request) != nil)
        clock.advance(.seconds(1))
        #expect(!fixture.canLockExclusively())
        clock.advance(.seconds(59))
        try await eventually { fixture.canLockExclusively() }
    }

    @Test func retryDrainsOldCompletionBeforeClearingFailureState() async throws {
        let fixture = try LeaseFixture()
        let entered = Gate(), finish = Gate()
        let inference = NextPromptInference(acquireLease: { try fixture.acquire() }, load: { _ in
            return { _ in
                await entered.open()
                await finish.wait()
                return #"{"suggestion":"Stale candidate."}"#
            }
        })
        let first = Task { try await inference.generate(request) }
        await entered.wait()
        let retry = Task { await inference.retryAfterFailure() }
        try await eventually { await inference.state == .unloading }
        #expect(!fixture.canLockExclusively())
        await finish.open()
        await retry.value
        #expect(try await first.value == nil)
        #expect(await inference.state == .ready)
        #expect(fixture.canLockExclusively())
    }

    @Test func invalidOutputConsumesOnlyItsTurn() async throws {
        let fixture = try LeaseFixture()
        let outputs = Mutex([#"{"suggestion":null}"#, "bad json", #"{"suggestion":"Delete the backup."}"#,
                             #"<tool_call>{"suggestion":"Show an example."}</tool_call>"#,
                             #"{"suggestion":"Show an example."}"#])
        let inference = NextPromptInference(acquireLease: { try fixture.acquire() }, load: { _ in
            return { _ in outputs.withLock { $0.removeFirst() } }
        })
        for _ in 0..<4 {
            #expect(try await inference.generate(request) == nil)
            #expect(await inference.state == .ready)
        }
        #expect(try await inference.generate(request) == "Show an example.")
        await inference.cancelAndUnload()
    }

    @Test func resourceFailuresSuppressAttemptsUntilRetry() async throws {
        let fixture = try LeaseFixture()
        let attempts = Mutex(0)
        let inference = NextPromptInference(acquireLease: { try fixture.acquire() }, load: { _ in
            return { _ in
                attempts.withLock { $0 += 1 }
                throw POSIXError(.ENOMEM)
            }
        })
        for _ in 0..<3 { _ = try await inference.generate(request) }
        #expect(attempts.withLock { $0 } == 2)
        #expect(await inference.state == .retryRequired)
        #expect(fixture.canLockExclusively())
        await inference.retryAfterFailure()
        _ = try await inference.generate(request)
        #expect(attempts.withLock { $0 } == 3)
    }

    @Test func unsupportedCapabilityNeverAcquiresAssets() async throws {
        let attempted = Mutex(false)
        let inference = NextPromptInference(acquireLease: {
            attempted.withLock { $0 = true }
            throw POSIXError(.EIO)
        }, load: { _ in { _ in nil } }, supported: { false })
        #expect(try await inference.generate(request) == nil)
        await inference.retryAfterFailure()
        #expect(await inference.state == .unavailable)
        #expect(!attempted.withLock { $0 })
    }

    @Test func callerCancellationInvalidatesBeforeDraining() async throws {
        let fixture = try LeaseFixture()
        let entered = Gate(), finish = Gate()
        let inference = NextPromptInference(acquireLease: { try fixture.acquire() }, load: { _ in
            return { _ in
                await entered.open()
                await finish.wait()
                return #"{"suggestion":"Late candidate."}"#
            }
        })
        let task = Task { try await inference.generate(request) }
        await entered.wait()
        task.cancel()
        do { try await eventually { await inference.state == .unloading } }
        catch {
            await finish.open()
            _ = try await task.value
            throw error
        }
        #expect(!fixture.canLockExclusively())
        await finish.open()
        #expect(try await task.value == nil)
        try await eventually { await inference.state == .ready }
        #expect(fixture.canLockExclusively())
    }

    @Test func callerCancellationAfterCompletionReleasesLeaseBeforeReturning() async throws {
        let fixture = try LeaseFixture()
        let completed = Mutex(false)
        let clock = NextPromptInference.Clock(now: {
            if CompletionCancellation.isCaller && completed.withLock({ $0 }) {
                // The caller has joined evaluation and is about to retain it for idle reuse.
                withUnsafeCurrentTask { $0?.cancel() }
            }
            return .now
        })
        let inference = NextPromptInference(acquireLease: { try fixture.acquire() }, load: { _ in
            return { _ in
                completed.withLock { $0 = true }
                return #"{"suggestion":"Completed candidate."}"#
            }
        }, clock: clock)
        try await Task {
            try await CompletionCancellation.$isCaller.withValue(true) {
                let result = try await inference.generate(request)
                #expect(result == nil)
                #expect(fixture.canLockExclusively())
            }
        }.value
        await inference.cancelAndUnload()
    }

    @Test func containerIsReleasedBeforeLeaseOnUnloadAndOwnerDeinit() async throws {
        let fixture = try LeaseFixture()
        let releasedUnderLease = Mutex<[Bool]>([])
        let load: @Sendable (URL) async throws -> NextPromptInference.Evaluation = { _ in
            let container = ContainerLifetime {
                releasedUnderLease.withLock { $0.append(!fixture.canLockExclusively()) }
            }
            return { _ in withExtendedLifetime(container) { #"{"suggestion":null}"# } }
        }
        var inference: NextPromptInference? = NextPromptInference(acquireLease: { try fixture.acquire() }, load: load)
        _ = try await inference?.generate(request)
        await inference?.cancelAndUnload()
        #expect(releasedUnderLease.withLock { $0 } == [true])
        _ = try await inference?.generate(request)
        inference = nil
        try await eventually { releasedUnderLease.withLock { $0.count == 2 } }
        #expect(releasedUnderLease.withLock { $0 } == [true, true])
        #expect(fixture.canLockExclusively())
    }

    @Test func deadlineRejectsCompletionEvenBeforeTimerResumes() async throws {
        let fixture = try LeaseFixture()
        let clock = ManualClock()
        let timer = Gate()
        let inference = NextPromptInference(acquireLease: { try fixture.acquire() }, load: { _ in
            return { _ in
                clock.advance(.seconds(15))
                return #"{"suggestion":"Late candidate."}"#
            }
        }, clock: .init(now: clock.clock.now, sleep: { _ in await timer.wait() }))
        #expect(try await inference.generate(request) == nil)
        await timer.open()
        #expect(await inference.state == .ready)
        #expect(fixture.canLockExclusively())
    }

    private var request: NextPromptRequest {
        .init(id: .init(sessionID: "test", incarnation: UUID(), promptID: 1, transcriptRevision: 1,
                        draftRevision: 0, composerEpoch: 0, settingsGeneration: 0, modelGeneration: 0),
              turns: [.init(user: "Explain binary search.", assistant: "It halves a sorted list.")])
    }
}

private final class LeaseFixture: Sendable {
    let directory: URL
    let path: String
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        path = directory.appendingPathComponent("lock").path
        FileManager.default.createFile(atPath: path, contents: Data())
    }
    func acquire() throws -> LocalTextModelLease {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        guard flock(handle.fileDescriptor, LOCK_SH | LOCK_NB) == 0 else { throw POSIXError(.EWOULDBLOCK) }
        return LocalTextModelLease(directory: directory, generation: 1, handle: handle)
    }
    func canLockExclusively() -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return false }
        defer { try? handle.close() }
        return flock(handle.fileDescriptor, LOCK_EX | LOCK_NB) == 0
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

private actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private func eventually(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !(await condition()) {
        try #require(ContinuousClock.now < deadline, "Condition did not become true")
        await Task.yield()
    }
}

private final class ManualClock: Sendable {
    struct State {
        var now = ContinuousClock.now
        var waiters: [UUID: (ContinuousClock.Instant, CheckedContinuation<Void, Error>)] = [:]
    }
    private let state = Mutex(State())
    var clock: NextPromptInference.Clock {
        .init(now: { self.state.withLock { $0.now } }, sleep: { deadline in
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    self.state.withLock {
                        if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                        else if $0.now >= deadline { continuation.resume() }
                        else { $0.waiters[id] = (deadline, continuation) }
                    }
                }
            } onCancel: {
                self.state.withLock { $0.waiters.removeValue(forKey: id)?.1.resume(throwing: CancellationError()) }
            }
        })
    }
    func advance(_ duration: Duration) {
        state.withLock {
            $0.now = $0.now.advanced(by: duration)
            let now = $0.now
            let ready = $0.waiters.filter { $0.value.0 <= now }
            for (id, waiter) in ready {
                $0.waiters[id] = nil
                waiter.1.resume()
            }
        }
    }
}

private final class ContainerLifetime: Sendable {
    let onRelease: @Sendable () -> Void
    init(_ onRelease: @escaping @Sendable () -> Void) { self.onRelease = onRelease }
    deinit { onRelease() }
}

private enum CompletionCancellation {
    @TaskLocal static var isCaller = false
}
