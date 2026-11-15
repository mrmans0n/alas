import Foundation
import Observation

/// Agent calls waiting for the user to hand a device (a simulator or a VM)
/// back: held in arrival order, released together, or given up after a limit.
@MainActor
@Observable
public final class HeldCalls {
    public enum Outcome: Equatable, Sendable {
        case released
        case timedOut
        case cancelled
    }

    private struct Call {
        let id: UUID
        let sessionID: String
        let token: String?
        let onRelease: @MainActor () -> Void
        let resume: CheckedContinuation<Outcome, Never>
        let timer: Task<Void, Never>
    }

    /// Per device key, in arrival order.
    private var held: [String: [Call]] = [:]
    @ObservationIgnored private let limit: Duration
    @ObservationIgnored private let sleep: @MainActor (Duration) async -> Void

    public init(
        limit: Duration = .seconds(50),
        sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.limit = limit
        self.sleep = sleep
    }

    /// Waits until `releaseAll(key)`, the limit, the caller's cancellation, or
    /// `cancel(token:)` with `token`. `onRelease` runs at release, in arrival
    /// order, before the call resumes.
    public func hold(
        _ key: String, sessionID: String, token: String? = nil, onRelease: @escaping @MainActor () -> Void = {}
    ) async -> Outcome {
        guard !Task.isCancelled else { return .cancelled }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let limit = limit
                let timer = Task { [weak self] in
                    await self?.sleep(limit)
                    guard !Task.isCancelled else { return }
                    self?.end(key, id: id, as: .timedOut)
                }
                held[key, default: []].append(Call(
                    id: id, sessionID: sessionID, token: token, onRelease: onRelease, resume: continuation, timer: timer
                ))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.end(key, id: id, as: .cancelled) }
        }
    }

    /// Lets every call held for `key` go, first to arrive first.
    public func releaseAll(_ key: String) {
        for call in held.removeValue(forKey: key) ?? [] {
            call.timer.cancel()
            call.onRelease()
            call.resume.resume(returning: .released)
        }
    }

    /// Cancels the held call `token` names, for a cancel that arrives as its
    /// own request rather than by the caller going away.
    public func cancel(token: String) {
        for (key, calls) in held {
            for call in calls where call.token == token { end(key, id: call.id, as: .cancelled) }
        }
    }

    /// The sessions whose calls wait for `key`, first to arrive first.
    public func waiting(_ key: String) -> [String] {
        held[key]?.map(\.sessionID) ?? []
    }

    private func end(_ key: String, id: UUID, as outcome: Outcome) {
        guard var calls = held[key], let index = calls.firstIndex(where: { $0.id == id }) else { return }
        let call = calls.remove(at: index)
        held[key] = calls.isEmpty ? nil : calls
        call.timer.cancel()
        call.resume.resume(returning: outcome)
    }
}
