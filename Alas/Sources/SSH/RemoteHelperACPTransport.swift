import Foundation

final class RemoteHelperACPTransport: @unchecked Sendable, JSONRPCStdioTransporting {
    private let host: String
    private let procId: String
    private let command: String
    private let arguments: [String]
    private let cwd: String
    private let environment: [String: String]
    private let pathPrefixDirectories: [String]
    private let state = State()
    private var continuation: AsyncStream<JSONRPCStdioTransport.Incoming>.Continuation?
    private var attachTask: Task<Void, Never>?
    private var stdoutOffset: UInt64 = 0
    private var stderrOffset: UInt64 = 0
    private var stdinOffset: UInt64 = 0

    let incoming: AsyncStream<JSONRPCStdioTransport.Incoming>

    init(
        host: String,
        procId: String,
        command: String,
        arguments: [String],
        cwd: String,
        environment: [String: String],
        pathPrefixDirectories: [String] = []
    ) {
        self.host = host
        self.procId = procId
        self.command = command
        self.arguments = arguments
        self.cwd = cwd
        self.environment = environment
        self.pathPrefixDirectories = pathPrefixDirectories
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
        guard state.enqueue(data) else { throw ACPClientError.notRunning }
        Task { [weak self] in
            await self?.flushPendingWrites()
        }
    }

    func terminate() {
        guard state.markTerminated() else { return }
        attachTask?.cancel()
        Task { [host, procId, stdoutOffset, stderrOffset] in
            let client = await RemoteHelperClientPool.shared.client(for: host)
            await client.detachProc(procId: procId, stdoutOffset: stdoutOffset, stderrOffset: stderrOffset)
        }
        continuation?.yield(.exited(0))
        continuation?.finish()
    }

    private func runAttachLoop() async {
        var didSpawn = false
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
                        _ = try await client.spawnProc(
                            procId: procId,
                            command: command,
                            args: arguments,
                            cwd: cwd,
                            env: environment,
                            pathPrefixDirectories: pathPrefixDirectories
                        )
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
                let requestedStdoutOffset = stdoutOffset == 0 ? nil : stdoutOffset
                let requestedStderrOffset = stderrOffset == 0 ? nil : stderrOffset
                let handle = try await client.attachProc(
                    procId: procId,
                    stdoutOffset: requestedStdoutOffset,
                    stderrOffset: requestedStderrOffset,
                    attachAtEndIfOffsetUnknown: true
                )
                stdinOffset = handle.stdinOffset
                attempt = 0
                for await event in handle.events {
                    guard !Task.isCancelled, !state.isTerminated else { return }
                    switch event {
                    case .available:
                        state.setWritesEnabled(true)
                        await flushPendingWrites()
                    case .unavailable:
                        state.setWritesEnabled(false)
                        throw RemoteHelperClientError.notRunning
                    case .stdout(let data, let offset):
                        stdoutOffset = offset
                        continuation?.yield(.frame(data))
                    case .stderr(let data, let offset):
                        stderrOffset = offset
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

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var started = false
        private var terminated = false
        private var canWrite = false
        private var isFlushingWrites = false
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

        func enqueue(_ data: Data) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !terminated else { return false }
            pendingWrites.append(PendingProcWrite(data: data, expectedStdinOffset: nil))
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

        func withExpectedStdinOffset(_ offset: UInt64) -> PendingProcWrite {
            PendingProcWrite(data: data, expectedStdinOffset: offset)
        }
    }
}
