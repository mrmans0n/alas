import Foundation

/// Runs `body` while a child process keeps a copy of `descriptor` open, as a
/// child another thread is spawning does until its exec closes it. A lock
/// released by `close` alone stays held for that long.
func withChildHolding<T>(_ descriptor: Int32, _ body: () throws -> T) throws -> T {
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    // dup2 onto another number clears close-on-exec on the child's copy; onto
    // the same number it does nothing, and exec would close it.
    posix_spawn_file_actions_adddup2(&actions, descriptor, descriptor == 3 ? 4 : 3)
    var pid: pid_t = 0
    let command: [String] = ["/bin/sleep", "60"]
    let arguments: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) } + [nil]
    defer { arguments.forEach { free($0) } }
    let status = posix_spawn(&pid, "/bin/sleep", &actions, nil, arguments, environ)
    guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO) }
    defer {
        kill(pid, SIGKILL)
        var exitStatus: Int32 = 0
        waitpid(pid, &exitStatus, 0)
    }
    return try body()
}
