import Foundation

final class RemoteHelperACPTransport: @unchecked Sendable, JSONRPCStdioTransporting {
    private let host: String
    private let procId: String
    private let command: String
    private let arguments: [String]
    private let cwd: String
    private let environment: [String: String]
    private let state = State()
    private var continuation: AsyncStream<JSONRPCStdioTransport.Incoming>.Continuation?
    private var attachTask: Task<Void, Never>?
    private var stdoutOffset: UInt64 = 0
    private var stderrOffset: UInt64 = 0

    let incoming: AsyncStream<JSONRPCStdioTransport.Incoming>

    init(
        host: String,
        procId: String,
        command: String,
        arguments: [String],
        cwd: String,
        environment: [String: String]
    ) {
        self.host = host
        self.procId = procId
        self.command = command
        self.arguments = arguments
        self.cwd = cwd
        self.environment = environment
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
        Task { [host, procId] in
            let client = await RemoteHelperClientPool.shared.client(for: host)
            try? await client.killProc(procId: procId)
        }
        continuation?.yield(.exited(0))
        continuation?.finish()
    }

    private func runAttachLoop() async {
        var didSpawn = false
        var attempt = 0
        while !Task.isCancelled && !state.isTerminated {
            do {
                let client = await RemoteHelperClientPool.shared.client(for: host)
                if !didSpawn {
                    let hello = try await client.hello()
                    guard hello.capabilities.proc == true else {
                        continuation?.yield(.exited(127))
                        continuation?.finish()
                        return
                    }
                    _ = try await client.spawnProc(
                        procId: procId,
                        command: command,
                        args: arguments,
                        cwd: cwd,
                        env: environment
                    )
                    didSpawn = true
                }
                let handle = try await client.attachProc(
                    procId: procId,
                    stdoutOffset: stdoutOffset,
                    stderrOffset: stderrOffset
                )
                attempt = 0
                await flushPendingWrites()
                for await event in handle.events {
                    guard !Task.isCancelled, !state.isTerminated else { return }
                    switch event {
                    case .available:
                        await flushPendingWrites()
                    case .unavailable:
                        throw RemoteHelperClientError.notRunning
                    case .stdout(let data, let offset):
                        stdoutOffset = offset
                        continuation?.yield(.frame(data))
                    case .stderr(let data, let offset):
                        stderrOffset = offset
                        continuation?.yield(.stderr(data))
                    case .exited(let code):
                        continuation?.yield(.exited(code ?? 0))
                        continuation?.finish()
                        return
                    }
                }
            } catch {
                guard !Task.isCancelled, !state.isTerminated else { return }
                let delay = ACPReconnectPolicy.delay(forAttempt: attempt) ?? 5
                attempt += 1
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private func flushPendingWrites() async {
        while !Task.isCancelled && !state.isTerminated {
            let next = state.takeNextWrite()
            guard let next else { return }
            do {
                let client = await RemoteHelperClientPool.shared.client(for: host)
                try await client.writeProc(procId: procId, data: next)
            } catch {
                state.requeue(next)
                return
            }
        }
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var started = false
        private var terminated = false
        private var pendingWrites: [Data] = []

        var isTerminated: Bool {
            lock.lock()
            defer { lock.unlock() }
            return terminated
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
            return true
        }

        func enqueue(_ data: Data) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !terminated else { return false }
            pendingWrites.append(data)
            return true
        }

        func takeNextWrite() -> Data? {
            lock.lock()
            defer { lock.unlock() }
            guard !pendingWrites.isEmpty else { return nil }
            return pendingWrites.removeFirst()
        }

        func requeue(_ data: Data) {
            lock.lock()
            defer { lock.unlock() }
            guard !terminated else { return }
            pendingWrites.insert(data, at: 0)
        }
    }
}
