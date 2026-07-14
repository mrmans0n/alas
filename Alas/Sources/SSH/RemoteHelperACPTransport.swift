import Foundation

final class RemoteHelperACPTransport: @unchecked Sendable, JSONRPCStdioTransporting {
    struct OutputOffsets: Equatable, Sendable {
        let stdout: UInt64?
        let stderr: UInt64?
    }

    private let host: String
    private let procId: String
    private let command: String
    private let arguments: [String]
    private let cwd: String
    private let environment: [String: String]
    private let pathPrefixDirectories: [String]
    private let onFreshProcSpawn: @MainActor @Sendable () async -> Void
    private let onOutputOffsetsChanged: @MainActor @Sendable (OutputOffsets) -> Void
    private let outputConsumption: OutputConsumptionTracker
    private let attachmentId = UUID().uuidString
    private let state = State()
    private var continuation: AsyncStream<JSONRPCStdioTransport.Incoming>.Continuation?
    private var attachTask: Task<Void, Never>?
    private var stdinOffset: UInt64 = 0

    let incoming: AsyncStream<JSONRPCStdioTransport.Incoming>
    var requestIDPrefix: String? { attachmentId }

    init(
        host: String,
        procId: String,
        command: String,
        arguments: [String],
        cwd: String,
        environment: [String: String],
        pathPrefixDirectories: [String] = [],
        initialOutputOffsets: OutputOffsets? = nil,
        onFreshProcSpawn: @escaping @MainActor @Sendable () async -> Void = {},
        onOutputOffsetsChanged: @escaping @MainActor @Sendable (OutputOffsets) -> Void = { _ in }
    ) {
        self.host = host
        self.procId = procId
        self.command = command
        self.arguments = arguments
        self.cwd = cwd
        self.environment = environment
        self.pathPrefixDirectories = pathPrefixDirectories
        self.onFreshProcSpawn = onFreshProcSpawn
        self.onOutputOffsetsChanged = onOutputOffsetsChanged
        self.outputConsumption = OutputConsumptionTracker(
            stdoutOffset: initialOutputOffsets?.stdout,
            stderrOffset: initialOutputOffsets?.stderr
        )
        var continuation: AsyncStream<JSONRPCStdioTransport.Incoming>.Continuation!
        self.incoming = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func start() throws {
        guard state.markStarted() else { return }
        attachTask = Task { [weak self] in
            await self?.runAttachLoop()
        }
    }

    func send(_ data: Data) throws {
        try enqueue(data, onWritten: nil)
    }

    func send(_ data: Data, onWritten: @escaping @Sendable () -> Void) throws {
        try enqueue(data, onWritten: onWritten)
    }

    private func enqueue(_ data: Data, onWritten: (@Sendable () -> Void)?) throws {
        guard state.enqueue(data, onWritten: onWritten) else { throw ACPClientError.notRunning }
        Task { [weak self] in
            await self?.flushPendingWrites()
        }
    }

    func terminate() {
        guard state.markTerminated() else { return }
        attachTask?.cancel()
        let offsets = outputConsumption.snapshot()
        Task { [host, procId, attachmentId, offsets] in
            let client = await RemoteHelperClientPool.shared.client(for: host)
            await client.detachProc(
                procId: procId,
                attachmentId: attachmentId,
                stdoutOffset: offsets.stdout ?? 0,
                stderrOffset: offsets.stderr ?? 0
            )
        }
        continuation?.yield(.exited(0))
        continuation?.finish()
    }

    private func runAttachLoop() async {
        var didSpawn = false
        var attachFreshSpawnFromStart = false
        var attempt = 0
        while !Task.isCancelled && !state.isTerminated {
            do {
                state.setWritesEnabled(false)
                let client = await RemoteHelperClientPool.shared.client(for: host)
                if !didSpawn {
                    let hello = try await client.hello()
                    guard hello.capabilities.proc == true else {
                        continuation?.yield(.exited(127))
                        continuation?.finish()
                        return
                    }
                    do {
                        let status = try await client.spawnProc(
                            procId: procId,
                            command: command,
                            args: arguments,
                            cwd: cwd,
                            env: environment,
                            pathPrefixDirectories: pathPrefixDirectories
                        )
                        attachFreshSpawnFromStart = status.spawned == true
                        if attachFreshSpawnFromStart {
                            await onFreshProcSpawn()
                            outputConsumption.reset(stdoutOffset: 0, stderrOffset: 0)
                        }
                    } catch {
                        guard Self.shouldRetrySpawnFailure(error) else {
                            state.setWritesEnabled(false)
                            let message = "Remote helper failed to launch ACP process: \(error.localizedDescription)\n"
                            continuation?.yield(.stderr(Data(message.utf8)))
                            continuation?.yield(.exited(127))
                            continuation?.finish()
                            return
                        }
                        throw error
                    }
                    didSpawn = true
                }
                let consumedOffsets = outputConsumption.snapshot()
                let requestedOffsets = Self.attachReplayOffsets(
                    stdoutOffset: consumedOffsets.stdout,
                    stderrOffset: consumedOffsets.stderr,
                    attachFreshSpawnFromStart: attachFreshSpawnFromStart
                )
                let handle = try await client.attachProc(
                    procId: procId,
                    attachmentId: attachmentId,
                    stdoutOffset: requestedOffsets.stdout,
                    stderrOffset: requestedOffsets.stderr
                )
                stdinOffset = handle.stdinOffset
                guard !Task.isCancelled, !state.isTerminated else {
                    let offsets = outputConsumption.snapshot()
                    await client.detachProc(
                        procId: procId,
                        attachmentId: attachmentId,
                        stdoutOffset: offsets.stdout ?? 0,
                        stderrOffset: offsets.stderr ?? 0
                    )
                    return
                }
                attempt = 0
                attachFreshSpawnFromStart = false
                var didBecomeAvailable = false
                for await event in handle.events {
                    guard !Task.isCancelled, !state.isTerminated else { return }
                    switch event {
                    case .available:
                        didBecomeAvailable = true
                        state.setWritesEnabled(true)
                        await flushPendingWrites()
                    case .unavailable:
                        state.setWritesEnabled(false)
                        throw RemoteHelperClientError.notRunning
                    case .stdout(let data, let offset):
                        guard let consumptionToken = outputConsumption.registerStdout(offset: offset) else {
                            continue
                        }
                        if !didBecomeAvailable,
                           Self.shouldSuppressPreAvailableReplayFrame(
                               data,
                               mayHaveDurableProcInput: state.mayHaveDurableProcInput
                           ) {
                            acknowledgeStdout(consumptionToken)
                            continue
                        }
                        continuation?.yield(.frame(data, onConsumed: { [weak self] in
                            self?.acknowledgeStdout(consumptionToken)
                        }))
                    case .stderr(let data, let offset):
                        publishOutputOffsets(outputConsumption.consumeStderr(offset: offset))
                        continuation?.yield(.stderr(data))
                    case .exited(let code):
                        state.setWritesEnabled(false)
                        continuation?.yield(.exited(code ?? 0))
                        continuation?.finish()
                        return
                    }
                }
            } catch {
                guard !Task.isCancelled, !state.isTerminated else { return }
                state.setWritesEnabled(false)
                await Self.sleepBeforeRetry(attempt: &attempt)
            }
        }
    }

    static func attachReplayOffsets(
        stdoutOffset: UInt64?,
        stderrOffset: UInt64?,
        attachFreshSpawnFromStart: Bool
    ) -> (stdout: UInt64?, stderr: UInt64?) {
        if attachFreshSpawnFromStart {
            return (0, 0)
        }
        return (stdoutOffset, stderrOffset)
    }

    private func acknowledgeStdout(_ token: OutputConsumptionTracker.StdoutToken) {
        guard let offsets = outputConsumption.consumeStdout(token: token) else { return }
        publishOutputOffsets(offsets)
    }

    private func publishOutputOffsets(_ offsets: OutputOffsets) {
        Task { @MainActor [onOutputOffsetsChanged] in
            onOutputOffsetsChanged(offsets)
        }
    }

    static func shouldSuppressPreAvailableReplayFrame(_ data: Data, mayHaveDurableProcInput: Bool) -> Bool {
        guard !mayHaveDurableProcInput else { return false }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return object["id"] != nil && object["method"] == nil
    }

    private func flushPendingWrites() async {
        var ownsFlush = false
        defer {
            if ownsFlush {
                state.endFlushingWrites()
            }
        }
        flushLoop: while !Task.isCancelled && !state.isTerminated {
            guard state.beginFlushingWrites() else { return }
            ownsFlush = true
            while !Task.isCancelled && !state.isTerminated {
                guard state.writesEnabled else {
                    state.endFlushingWrites()
                    ownsFlush = false
                    return
                }
                let next = state.takeNextWrite()
                guard let next else {
                    if state.endFlushingWritesAndShouldRestart() {
                        ownsFlush = false
                        continue flushLoop
                    }
                    ownsFlush = false
                    return
                }
                let expectedStdinOffset = next.expectedStdinOffset ?? stdinOffset
                do {
                    let client = await RemoteHelperClientPool.shared.client(for: host)
                    stdinOffset = try await client.writeProc(
                        procId: procId,
                        data: Self.frameForProcWrite(next.data),
                        expectedStdinOffset: expectedStdinOffset
                    )
                    next.onWritten?()
                    state.markMayHaveDurableProcInput()
                } catch RemoteHelperClientError.jsonrpc(let error) {
                    _ = state.markTerminated()
                    let message = "Remote helper failed to write ACP input: \(error.message)\n"
                    continuation?.yield(.stderr(Data(message.utf8)))
                    continuation?.yield(.exited(127))
                    continuation?.finish()
                    state.endFlushingWrites()
                    ownsFlush = false
                    return
                } catch {
                    state.markMayHaveDurableProcInput()
                    state.requeueForOffsetGuardedRetry(next.withExpectedStdinOffset(expectedStdinOffset))
                    state.endFlushingWrites()
                    ownsFlush = false
                    return
                }
            }
            state.endFlushingWrites()
            ownsFlush = false
            return
        }
    }

    static func frameForProcWrite(_ data: Data) -> Data {
        JSONRPCNewlineFramer.encode(data)
    }

    static func shouldRetrySpawnFailure(_ error: Error) -> Bool {
        guard let error = error as? RemoteHelperClientError else { return false }
        switch error {
        case .notRunning, .unavailable:
            return true
        case .jsonrpc, .decoding:
            return false
        }
    }

    private static func sleepBeforeRetry(attempt: inout Int) async {
        let delay = ACPReconnectPolicy.delay(forAttempt: attempt) ?? 5
        attempt += 1
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }

    final class OutputConsumptionTracker: @unchecked Sendable {
        struct StdoutToken: Equatable, Sendable {
            let generation: UInt64
            let offset: UInt64
        }

        private struct PendingStdout {
            let token: StdoutToken
            var consumed: Bool
        }

        private let lock = NSLock()
        private var stdoutOffset: UInt64?
        private var stderrOffset: UInt64?
        private var pendingStdout: [PendingStdout] = []
        private var generation: UInt64 = 0

        init(stdoutOffset: UInt64?, stderrOffset: UInt64?) {
            self.stdoutOffset = stdoutOffset
            self.stderrOffset = stderrOffset
        }

        func reset(stdoutOffset: UInt64?, stderrOffset: UInt64?) {
            lock.lock()
            defer { lock.unlock() }
            self.stdoutOffset = stdoutOffset
            self.stderrOffset = stderrOffset
            pendingStdout.removeAll(keepingCapacity: true)
            generation &+= 1
        }

        func snapshot() -> OutputOffsets {
            lock.lock()
            defer { lock.unlock() }
            return OutputOffsets(stdout: stdoutOffset, stderr: stderrOffset)
        }

        func registerStdout(offset: UInt64) -> StdoutToken? {
            lock.lock()
            defer { lock.unlock() }
            if let stdoutOffset, stdoutOffset >= offset { return nil }
            if pendingStdout.contains(where: { $0.token.offset == offset }) { return nil }
            let token = StdoutToken(generation: generation, offset: offset)
            pendingStdout.append(.init(token: token, consumed: false))
            return token
        }

        func consumeStdout(token: StdoutToken) -> OutputOffsets? {
            lock.lock()
            defer { lock.unlock() }
            guard token.generation == generation,
                  let index = pendingStdout.firstIndex(where: { $0.token == token && !$0.consumed })
            else {
                return nil
            }
            pendingStdout[index].consumed = true
            var advanced = false
            while pendingStdout.first?.consumed == true {
                stdoutOffset = pendingStdout.removeFirst().token.offset
                advanced = true
            }
            guard advanced else { return nil }
            return OutputOffsets(stdout: stdoutOffset, stderr: stderrOffset)
        }

        func consumeStderr(offset: UInt64) -> OutputOffsets {
            lock.lock()
            defer { lock.unlock() }
            if stderrOffset == nil || stderrOffset! < offset {
                stderrOffset = offset
            }
            return OutputOffsets(stdout: stdoutOffset, stderr: stderrOffset)
        }
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var started = false
        private var terminated = false
        private var canWrite = false
        private var isFlushingWrites = false
        private var mayHaveDurableInput = false
        private var pendingWrites: [PendingProcWrite] = []

        var isTerminated: Bool {
            lock.lock()
            defer { lock.unlock() }
            return terminated
        }

        var writesEnabled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return canWrite && !terminated
        }

        var mayHaveDurableProcInput: Bool {
            lock.lock()
            defer { lock.unlock() }
            return mayHaveDurableInput
        }

        func markStarted() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !started else { return false }
            started = true
            return true
        }

        func markTerminated() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !terminated else { return false }
            terminated = true
            canWrite = false
            return true
        }

        func setWritesEnabled(_ enabled: Bool) {
            lock.lock()
            defer { lock.unlock() }
            canWrite = enabled && !terminated
        }

        func markMayHaveDurableProcInput() {
            lock.lock()
            defer { lock.unlock() }
            mayHaveDurableInput = true
        }

        func enqueue(_ data: Data, onWritten: (@Sendable () -> Void)?) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !terminated else { return false }
            pendingWrites.append(PendingProcWrite(
                data: data,
                expectedStdinOffset: nil,
                onWritten: onWritten
            ))
            return true
        }

        func takeNextWrite() -> PendingProcWrite? {
            lock.lock()
            defer { lock.unlock() }
            guard !pendingWrites.isEmpty else { return nil }
            return pendingWrites.removeFirst()
        }

        func beginFlushingWrites() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !isFlushingWrites, !terminated else { return false }
            isFlushingWrites = true
            return true
        }

        func endFlushingWrites() {
            lock.lock()
            defer { lock.unlock() }
            isFlushingWrites = false
        }

        func endFlushingWritesAndShouldRestart() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            isFlushingWrites = false
            return canWrite && !terminated && !pendingWrites.isEmpty
        }

        func requeueForOffsetGuardedRetry(_ write: PendingProcWrite) {
            lock.lock()
            defer { lock.unlock() }
            guard !terminated else { return }
            pendingWrites.insert(write, at: 0)
        }
    }

    private struct PendingProcWrite {
        let data: Data
        let expectedStdinOffset: UInt64?
        let onWritten: (@Sendable () -> Void)?

        func withExpectedStdinOffset(_ offset: UInt64) -> PendingProcWrite {
            PendingProcWrite(data: data, expectedStdinOffset: offset, onWritten: onWritten)
        }
    }
}
