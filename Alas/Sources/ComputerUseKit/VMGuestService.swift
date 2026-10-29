import AlasCore
import Darwin
import Foundation
import os

/// What `VMGuestService` needs from `ComputerUseCoordinator`.
@MainActor
public protocol VMGuestCoordinating: AnyObject {
    func perform(_ command: ComputerUseCommand, sessionID: String) async -> AlasCLIResponse
    func stop(sessionID: String) async
    func resume(sessionID: String)
    func turnEnded(sessionID: String)
    func sessionEnded(sessionID: String)
}

extension ComputerUseCoordinator: VMGuestCoordinating {}

/// The outcome of a `vm_run` command. `exitCode` is nil when a signal ended the shell.
public struct VMGuestRunResult: Equatable, Sendable {
    public var exitCode: Int32?
    public var stdout: String
    public var stderr: String
    /// Either stream kept only its last `VMGuestShellRunner.outputLimit` bytes.
    public var truncated: Bool
    public var timedOut: Bool

    public init(exitCode: Int32?, stdout: String, stderr: String, truncated: Bool, timedOut: Bool) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.truncated = truncated
        self.timedOut = timedOut
    }
}

public protocol VMGuestCommandRunning: Sendable {
    func run(_ command: String, timeout: Duration) async -> VMGuestRunResult
}

/// Answers the host's messages inside the guest: computer-use calls through the coordinator,
/// lifecycle events, and `vm_run` commands. Request ids are the host's, so they are scoped to the
/// connection they arrived on.
@MainActor
public final class VMGuestService {
    public static let defaultRunTimeoutSeconds = 120
    public static let maxRunTimeoutSeconds = 600

    private struct RequestKey: Hashable {
        var connection: UInt64
        var id: UInt64
    }

    private let coordinator: VMGuestCoordinating
    private let permissions: () -> (accessibility: Bool, screenRecording: Bool)
    private let runner: VMGuestCommandRunning
    private let version: String
    /// Commands and runs in flight. Cancelling one's task cancels the work: `perform` forwards its
    /// caller's cancellation to the call it runs, and the runner ends the command's process group.
    private var inFlight: [RequestKey: Task<VMGuestMessage, Never>] = [:]
    /// The sessions each connection has used and not ended, so a disconnect can end them.
    private var sessions: [UInt64: Set<String>] = [:]
    /// Connections that closed: work still queued from them is dropped, not started.
    private var closedConnections: Set<UInt64> = []

    private static let log = Logger(subsystem: "io.nlopez.vmguest", category: "service")

    public init(
        coordinator: VMGuestCoordinating,
        permissions: @escaping () -> (accessibility: Bool, screenRecording: Bool),
        runner: VMGuestCommandRunning,
        version: String
    ) {
        self.coordinator = coordinator
        self.permissions = permissions
        self.runner = runner
        self.version = version
    }

    /// The reply to send back on `connection`, if the message has one.
    public func handle(_ message: VMGuestMessage, connection: UInt64 = 0) async -> VMGuestMessage? {
        guard !closedConnections.contains(connection) else { return nil }
        switch message {
        case .hello:
            let grants = permissions()
            return .helloReply(
                guestVersion: version, protocolRevision: VMGuestProtocol.revision,
                accessibility: grants.accessibility, screenRecording: grants.screenRecording)
        case let .command(id, sessionID, request):
            sessions[connection, default: []].insert(sessionID)
            let command: ComputerUseCommand
            do {
                command = try Self.decode(request)
            } catch {
                return .response(
                    id: id, body: Self.encode(.error("computer_malformed: The VM guest helper couldn't read the request.")))
            }
            if command.action != .cancel, let refusal = Self.missingGrantsError(permissions()) {
                return .response(id: id, body: Self.encode(.error(refusal)))
            }
            let coordinator = coordinator
            return await track(RequestKey(connection: connection, id: id)) {
                .response(id: id, body: Self.encode(await coordinator.perform(command, sessionID: sessionID)))
            }
        case let .cancel(id):
            inFlight[RequestKey(connection: connection, id: id)]?.cancel()
            return nil
        case let .lifecycle(sessionID, event):
            switch event {
            case .stop: await coordinator.stop(sessionID: sessionID)
            case .resume: coordinator.resume(sessionID: sessionID)
            case .turnEnded: coordinator.turnEnded(sessionID: sessionID)
            case .sessionEnded:
                sessions[connection]?.remove(sessionID)
                coordinator.sessionEnded(sessionID: sessionID)
            }
            return nil
        case let .run(id, command, timeoutSeconds):
            let seconds = timeoutSeconds > 0 ? min(timeoutSeconds, Self.maxRunTimeoutSeconds) : Self.defaultRunTimeoutSeconds
            let runner = runner
            return await track(RequestKey(connection: connection, id: id)) {
                let result = await runner.run(command, timeout: .seconds(seconds))
                return .runResult(
                    id: id, exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr,
                    truncated: result.truncated, timedOut: result.timedOut)
            }
        case .helloReply, .response, .runResult:
            Self.log.error("ignoring a guest-to-host message sent to the guest")
            return nil
        }
    }

    /// The host went away: nobody waits for the connection's answers, and its sessions would keep
    /// the driver lock and their refs until a session that no longer exists ended them.
    public func connectionClosed(_ connection: UInt64) {
        closedConnections.insert(connection)
        for (key, task) in inFlight where key.connection == connection { task.cancel() }
        for sessionID in sessions.removeValue(forKey: connection) ?? [] {
            coordinator.turnEnded(sessionID: sessionID)
            coordinator.sessionEnded(sessionID: sessionID)
        }
    }

    private func track(
        _ key: RequestKey, _ work: @escaping @MainActor () async -> VMGuestMessage
    ) async -> VMGuestMessage {
        let task = Task { await work() }
        inFlight[key] = task
        let reply = await task.value
        if inFlight[key] == task { inFlight[key] = nil }
        return reply
    }

    /// The guest's own grants, named for where they are given: the readiness text points at the
    /// host's Alas Settings, which can't grant anything inside the VM.
    static func missingGrantsError(_ grants: (accessibility: Bool, screenRecording: Bool)) -> String? {
        var missing: [ComputerUsePermission] = []
        if !grants.accessibility { missing.append(.accessibility) }
        if !grants.screenRecording { missing.append(.screenRecording) }
        guard !missing.isEmpty else { return nil }
        let names = missing.map(\.displayName).joined(separator: " and ")
        let pronoun = missing.count == 1 ? "it" : "them"
        return "computer_permissions: Alas VM Guest is missing \(names) in this VM. "
            + "Ask the user to grant \(pronoun) in the VM's System Settings › Privacy & Security."
    }

    /// `request` is `ComputerUseCommand.requestJSON()`: `{"command":"computer_<action>","params":{…}}`.
    private static func decode(_ request: Data) throws -> ComputerUseCommand {
        guard let object = try JSONSerialization.jsonObject(with: request) as? [String: Any],
              let name = object["command"] as? String, name.hasPrefix("computer_"),
              let action = ComputerUseCommand.Action(rawValue: String(name.dropFirst("computer_".count)))
        else { throw AlasCLIRequestError.malformed }
        return try ComputerUseCommand.decode(action: action, data: request)
    }

    private static func encode(_ response: AlasCLIResponse) -> Data {
        (try? response.encode()) ?? Data(#"{"ok":false,"error":"computer_internal: The response couldn't be encoded."}"#.utf8)
    }

    /// The helper's service: the real executor, every action allowed (the VM is the sandbox), and
    /// readiness from the guest's own Accessibility and Screen Recording grants.
    public static func makeLive() -> VMGuestService {
        let platform = ComputerUseSystemPermissions.make()
        let grants: () -> (accessibility: Bool, screenRecording: Bool) = {
            (platform.isGranted(.accessibility), platform.isGranted(.screenRecording))
        }
        let coordinator = ComputerUseCoordinator(
            system: .live(),
            access: ComputerUseAccess(hostPID: getpid(), alwaysAllowed: { [] }, mode: .guest),
            readiness: {
                ComputerUseReadiness.evaluate(
                    enabled: true, granted: Set(ComputerUsePermission.allCases.filter(platform.isGranted)))
            },
            sessionLabel: { $0 },
            persistAlwaysAllowed: { _ in },
            interrupt: { _ in },
            cursor: .none,
            attention: {}
        )
        coordinator.autoRun = { _ in true }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return VMGuestService(coordinator: coordinator, permissions: grants, runner: VMGuestShellRunner(), version: version)
    }
}

/// Runs `vm_run` commands with `shellArguments` (`/bin/zsh -lc` by default) in their own process group, as the helper's user.
public struct VMGuestShellRunner: VMGuestCommandRunning {
    /// Bytes kept from the end of each of stdout and stderr.
    public static let outputLimit = 256 * 1024

    /// The shell and its options; the command is appended as the last argument.
    public var shellArguments = ["/bin/zsh", "-lc"]
    /// Between the SIGTERM and the SIGKILL of a timed-out or cancelled command's process group.
    public var killGrace: Duration = .seconds(2)
    /// After the SIGKILL, how long to keep waiting for the output to close. A process that left the
    /// group can hold it open indefinitely; the result then carries what arrived so far.
    public var closeGrace: Duration = .milliseconds(500)

    public init() {}

    /// Returns once the shell has exited and both streams are closed, so a background child that
    /// keeps them open runs into the timeout like the shell would. A cancellation ends the
    /// command's process group the way a timeout does.
    public func run(_ command: String, timeout: Duration) async -> VMGuestRunResult {
        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0 else { return Self.failure(errno) }
        guard pipe(&errPipe) == 0 else {
            let code = errno
            close(outPipe[0])
            close(outPipe[1])
            return Self.failure(code)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Its own process group, so a timeout reaches the whole pipeline; no inherited descriptors
        // beyond the three above, so a command never holds the host connection open. Default
        // signal handling and an empty mask: the helper ignores SIGPIPE, and a pipeline like
        // `yes | head` relies on it.
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)

        guard let shell = shellArguments.first else { return Self.failure(ENOENT) }
        let arguments = shellArguments + [command]
        let environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environment.map { strdup($0) } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, shell, &actions, &attributes, argv, envp)
        close(outPipe[1])
        close(errPipe[1])
        guard spawned == 0 else {
            close(outPipe[0])
            close(errPipe[0])
            return Self.failure(spawned)
        }

        let group = ProcessGroup(leader: pid)
        let stdout = OutputTail(limit: Self.outputLimit)
        let stderr = OutputTail(limit: Self.outputLimit)
        let finished = Latch()
        let outRead = outPipe[0]
        let errRead = errPipe[0]
        Task {
            async let outDone: Void = Self.drain(outRead, into: stdout)
            async let errDone: Void = Self.drain(errRead, into: stderr)
            await group.waitForLeaderExit()
            _ = await (outDone, errDone)
            finished.open()
        }
        let stopGroup: @Sendable (Bool) -> Task<Void, Never> = { [killGrace, closeGrace] deadline in
            Task {
                if deadline {
                    do { try await Task.sleep(for: timeout) } catch { return }
                    group.markTimedOut()
                }
                group.signal(SIGTERM)
                try? await Task.sleep(for: killGrace)
                group.signal(SIGKILL)
                try? await Task.sleep(for: closeGrace)
                // Whatever still holds the output left the group; stop waiting for it.
                finished.open()
            }
        }
        let deadline = stopGroup(true)
        await withTaskCancellationHandler {
            await finished.wait()
        } onCancel: {
            _ = stopGroup(false)
        }
        deadline.cancel()

        let status = group.reap()
        // A wait status: the low 7 bits are the terminating signal, 0 for a normal exit.
        let exitCode: Int32? = status & 0x7F == 0 ? (status >> 8) & 0xFF : nil
        let out = stdout.snapshot()
        let err = stderr.snapshot()
        return VMGuestRunResult(
            exitCode: exitCode, stdout: String(decoding: out.bytes, as: UTF8.self),
            stderr: String(decoding: err.bytes, as: UTF8.self), truncated: out.truncated || err.truncated,
            timedOut: group.timedOut)
    }

    private static func failure(_ code: Int32) -> VMGuestRunResult {
        VMGuestRunResult(
            exitCode: nil, stdout: "", stderr: "vm_run: couldn't start the shell: \(String(cString: strerror(code)))",
            truncated: false, timedOut: false)
    }

    /// Reads `fd` to its end on a thread of its own (the reads block), then closes it.
    private static func drain(_ fd: Int32, into tail: OutputTail) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread {
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    let count = read(fd, &buffer, buffer.count)
                    if count > 0 {
                        tail.append(buffer[..<count])
                    } else if count < 0, errno == EINTR {
                        continue
                    } else {
                        break
                    }
                }
                close(fd)
                continuation.resume()
            }
        }
    }
}

/// A command's process group. The leader is left a zombie until `reap()`, so its pid, which is
/// the group id, can't be recycled while the group may still be signalled; after `reap()` no
/// signal is sent.
private final class ProcessGroup: @unchecked Sendable {
    private let lock = NSLock()
    private let leader: pid_t
    private var reaped = false
    private var didTimeOut = false
    private var terminating = false

    init(leader: pid_t) { self.leader = leader }

    var timedOut: Bool { lock.withLock { didTimeOut } }

    func markTimedOut() { lock.withLock { didTimeOut = true } }

    func signal(_ signal: Int32) {
        lock.withLock {
            guard !reaped else { return }
            if signal == SIGTERM { terminating = true }
            killpg(leader, signal)
        }
    }

    /// Waits for the leader to exit without reaping it (`WNOWAIT`).
    func waitForLeaderExit() async {
        let leader = leader
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread {
                var info = siginfo_t()
                while waitid(P_PID, id_t(leader), &info, WEXITED | WNOWAIT) < 0, errno == EINTR {}
                continuation.resume()
            }
        }
    }

    /// Reaps the leader and returns its wait status; the group is not signalled after this.
    /// Once termination started, a member that outlived SIGTERM is killed first: the unreaped
    /// leader still holds the group id, so the kill can't reach a recycled group.
    func reap() -> Int32 {
        lock.withLock {
            if terminating { killpg(leader, SIGKILL) }
            reaped = true
            var status: Int32 = 0
            while waitpid(leader, &status, 0) < 0, errno == EINTR {}
            return status
        }
    }
}

/// Opens once; `wait()` returns as soon as it is open.
private final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        let resumed: [CheckedContinuation<Void, Never>] = lock.withLock {
            guard !isOpen else { return [] }
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        for waiter in resumed { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = lock.withLock {
                if !isOpen { waiters.append(continuation) }
                return isOpen
            }
            if ready { continuation.resume() }
        }
    }
}

/// The last `limit` bytes appended to it. Appends may continue after a snapshot, from a reader
/// still draining a stream a detached process holds open.
private final class OutputTail: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var bytes: [UInt8] = []
    private var dropped = false

    init(limit: Int) { self.limit = limit }

    func append(_ chunk: ArraySlice<UInt8>) {
        lock.withLock {
            bytes.append(contentsOf: chunk)
            // Trim in batches, not on every read.
            if bytes.count > 2 * limit { trim() }
        }
    }

    func snapshot() -> (bytes: [UInt8], truncated: Bool) {
        lock.withLock {
            if bytes.count > limit { trim() }
            return (bytes, dropped)
        }
    }

    private func trim() {
        bytes.removeFirst(bytes.count - limit)
        dropped = true
    }
}
