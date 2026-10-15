import Testing

/// Waits until `condition` holds, polling, and records an issue and throws
/// if it does not within `timeout`.
func eventually(
    within timeout: Duration = .seconds(10),
    _ condition: @escaping @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !(await condition()) {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out waiting for condition")
            throw CancellationError()
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}
