import Testing

/// Waits until `condition` holds, polling, and records an issue and throws
/// if it does not within `timeout`.
/// The full package runs over a thousand tests concurrently on small CI
/// runners. Readiness waits need room for scheduling and fixture I/O; tests
/// that assert a latency bound can still supply their own shorter timeout.
func eventually(
    within timeout: Duration = .seconds(60),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @escaping @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !(await condition()) {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out waiting for condition", sourceLocation: sourceLocation)
            throw CancellationError()
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}
