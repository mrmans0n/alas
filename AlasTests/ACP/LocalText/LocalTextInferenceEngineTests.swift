import Darwin
import Foundation
import Synchronization
import Testing
@testable import Alas

@Suite(.serialized)
struct LocalTextInferenceEngineTests {
    @Test func userRequestCancelsAndDrainsAutomaticWorkBeforeStarting() async throws {
        let probe = try LocalTextEngineProbe()
        let engine = probe.engine()
        let automatic = Task {
            try await engine.generate(request, caller: .nextPrompt, priority: .automatic)
        }
        await probe.waitUntilEvaluationStarts(0)

        let summary = Task {
            try await engine.generate(request, caller: .sessionSummary(UUID()), priority: .userInitiated)
        }
        await probe.waitUntilEvaluationIsCancelled(0)
        #expect(probe.startedEvaluationCount == 1)
        probe.finishEvaluation(0, with: "ignored")
        await probe.waitUntilEvaluationStarts(1)
        #expect(probe.leaseWasClosedBeforeFirstDrain == false)
        probe.finishEvaluation(1, with: "summary")

        await #expect(throws: LocalTextInferenceFailure.preempted) { try await automatic.value }
        #expect(try await summary.value.text == "summary")
    }

    @Test func automaticRequestCannotPreemptUserRequest() async throws {
        let probe = try LocalTextEngineProbe()
        let engine = probe.engine()
        let user = Task {
            try await engine.generate(request, caller: .sessionSummary(UUID()), priority: .userInitiated)
        }
        await probe.waitUntilEvaluationStarts(0)

        await #expect(throws: LocalTextInferenceFailure.preempted) {
            try await engine.generate(request, caller: .nextPrompt, priority: .automatic)
        }
        #expect(probe.cancelledEvaluationCount == 0)
        probe.finishEvaluation(0, with: "summary")
        #expect(try await user.value.text == "summary")
    }

    @Test func newerUserRequestReplacesOlderUserRequest() async throws {
        let probe = try LocalTextEngineProbe()
        let engine = probe.engine()
        let first = Task {
            try await engine.generate(request, caller: .sessionSummary(UUID()), priority: .userInitiated)
        }
        await probe.waitUntilEvaluationStarts(0)
        let second = Task {
            try await engine.generate(request, caller: .sessionSummary(UUID()), priority: .userInitiated)
        }
        await probe.waitUntilEvaluationIsCancelled(0)
        #expect(probe.startedEvaluationCount == 1)
        probe.finishEvaluation(0, with: "ignored")
        await probe.waitUntilEvaluationStarts(1)
        probe.finishEvaluation(1, with: "new")

        await #expect(throws: LocalTextInferenceFailure.cancelled) { try await first.value }
        #expect(try await second.value.text == "new")
    }

    @Test func callerCancellationDrainsBeforeLeaseCloses() async throws {
        let probe = try LocalTextEngineProbe()
        let engine = probe.engine()
        let task = Task {
            try await engine.generate(request, caller: .nextPrompt, priority: .automatic)
        }
        await probe.waitUntilEvaluationStarts(0)
        let cancellation = Task { await engine.cancel(caller: .nextPrompt) }
        await probe.waitUntilEvaluationIsCancelled(0)
        #expect(!probe.leaseIsClosed)
        probe.finishEvaluation(0, with: "ignored")
        await cancellation.value

        await #expect(throws: LocalTextInferenceFailure.cancelled) { try await task.value }
        #expect(probe.firstDrainPrecededLeaseClose)
        #expect(probe.leaseIsClosed)
    }

    @Test func selectsFirstCandidateWithinTokenLimit() async throws {
        let fixture = try EngineLeaseFixture()
        let engine = LocalTextInferenceEngine(
            acquireLease: { try fixture.acquire() },
            load: { _ in
                { request in
                    let counts = request.messageCandidates.map { Int($0[0].content)! }
                    guard let index = counts.firstIndex(where: { $0 <= request.inputTokenLimit }) else {
                        throw LocalTextInferenceFailure.inputTooLarge
                    }
                    return .init(text: "selected", selectedCandidateIndex: index)
                }
            },
            supported: { true }
        )
        let result = try await engine.generate(
            .init(messageCandidates: [9_000, 7_000, 1_000].map { [.init(role: .user, content: String($0))] },
                  inputTokenLimit: 8_192, maxTokens: 8, temperature: 0, prefillStepSize: 512,
                  timeout: .seconds(15)),
            caller: .nextPrompt,
            priority: .automatic
        )
        #expect(result.selectedCandidateIndex == 1)
        await engine.cancelAndUnload()
    }

    @Test func deadlineCancelsGenerationAndUnloads() async throws {
        let probe = try LocalTextEngineProbe()
        let engine = probe.engine()
        let task = Task {
            try await engine.generate(request, caller: .nextPrompt, priority: .automatic)
        }
        await probe.waitUntilEvaluationStarts(0)
        probe.clock.advance(.seconds(15))
        await probe.waitUntilEvaluationIsCancelled(0)
        #expect(!probe.leaseIsClosed)
        probe.finishEvaluation(0, with: "ignored")

        await #expect(throws: LocalTextInferenceFailure.timedOut) { try await task.value }
        #expect(probe.firstDrainPrecededLeaseClose)
        #expect(probe.leaseIsClosed)
    }

    @Test func idleDeadlineUnloadsAfterSixtySeconds() async throws {
        let probe = try LocalTextEngineProbe()
        let engine = probe.engine()
        let task = Task {
            try await engine.generate(request, caller: .nextPrompt, priority: .automatic)
        }
        await probe.waitUntilEvaluationStarts(0)
        probe.finishEvaluation(0, with: "done")
        #expect(try await task.value.text == "done")

        probe.clock.advance(.seconds(59))
        await Task.yield()
        #expect(!probe.leaseIsClosed)
        probe.clock.advance(.seconds(1))
        await probe.waitUntilLeaseCloses()
        #expect(probe.leaseIsClosed)
    }

    private var request: LocalTextGenerationRequest {
        .init(messageCandidates: [[.init(role: .user, content: "test")]], inputTokenLimit: 8_192,
              maxTokens: 8, temperature: 0, prefillStepSize: 512, timeout: .seconds(15))
    }
}

private final class LocalTextEngineProbe: Sendable {
    let clock = LocalTextManualClock()
    private let fixture: EngineLeaseFixture
    private let state = Mutex(State())
    private let starts = [EngineGate(), EngineGate()]
    private let cancellations = [EngineGate(), EngineGate()]
    private let finishes = [EngineValueGate(), EngineValueGate()]

    private struct State {
        var starts = 0
        var cancellations = 0
        var firstDrained = false
        var closedBeforeFirstDrain = false
    }

    init() throws { fixture = try EngineLeaseFixture() }

    var startedEvaluationCount: Int { state.withLock(\.starts) }
    var cancelledEvaluationCount: Int { state.withLock(\.cancellations) }
    var leaseWasClosedBeforeFirstDrain: Bool { state.withLock(\.closedBeforeFirstDrain) }
    var firstDrainPrecededLeaseClose: Bool { state.withLock { $0.firstDrained && !$0.closedBeforeFirstDrain } }
    var leaseIsClosed: Bool { fixture.canLockExclusively() }

    func engine() -> LocalTextInferenceEngine {
        LocalTextInferenceEngine(
            acquireLease: { try self.fixture.acquire() },
            load: { _ in
                { request in
                    let index = self.state.withLock { state in
                        let index = state.starts
                        state.starts += 1
                        return index
                    }
                    await self.starts[index].open()
                    let value = await withTaskCancellationHandler {
                        await self.finishes[index].wait()
                    } onCancel: {
                        self.state.withLock { $0.cancellations += 1 }
                        Task { await self.cancellations[index].open() }
                    }
                    if index == 0 {
                        self.state.withLock {
                            $0.closedBeforeFirstDrain = self.fixture.canLockExclusively()
                            $0.firstDrained = true
                        }
                    }
                    return .init(text: value, selectedCandidateIndex: 0)
                }
            },
            supported: { true },
            clock: clock.clock,
            observeMemoryPressure: false
        )
    }

    func waitUntilEvaluationStarts(_ index: Int) async { await starts[index].wait() }
    func waitUntilEvaluationIsCancelled(_ index: Int) async { await cancellations[index].wait() }
    func finishEvaluation(_ index: Int, with value: String) { Task { await finishes[index].open(value) } }
    func waitUntilLeaseCloses() async {
        while !fixture.canLockExclusively() { await Task.yield() }
    }
}

private final class EngineLeaseFixture: Sendable {
    let directory: URL
    private let path: String

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

private actor EngineGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor EngineValueGate {
    private var value: String?
    private var waiters: [CheckedContinuation<String, Never>] = []
    func wait() async -> String {
        if let value { return value }
        return await withCheckedContinuation { waiters.append($0) }
    }
    func open(_ value: String) {
        self.value = value
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(returning: value) }
    }
}

private final class LocalTextManualClock: Sendable {
    struct State {
        var now = ContinuousClock.now
        var waiters: [UUID: (ContinuousClock.Instant, CheckedContinuation<Void, Error>)] = [:]
    }
    private let state = Mutex(State())

    var clock: LocalTextInferenceEngine.Clock {
        .init(now: { self.state.withLock(\.now) }, sleep: { deadline in
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
