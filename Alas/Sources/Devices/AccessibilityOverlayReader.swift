import AlasCore
import Foundation
import Observation

/// The accessibility overlay's reads of a simulator's element tree. A read
/// that another started after supersedes it: `describe` can't be cancelled,
/// so an older reply that arrives later is dropped.
@MainActor
@Observable
final class AccessibilityOverlayReader {
    private(set) var snapshot: DeviceSnapshot?
    private(set) var reading = false
    private(set) var error: String?
    @ObservationIgnored private let describe: () async throws -> Data
    @ObservationIgnored private var latest = 0

    init(describe: @escaping () async throws -> Data) {
        self.describe = describe
    }

    func read() async {
        latest += 1
        let generation = latest
        reading = true
        let result: Result<DeviceSnapshot, Error>
        do {
            result = .success(try DeviceSnapshot.parse(try await describe(), generation: 0))
        } catch {
            result = .failure(error)
        }
        guard generation == latest else { return }
        reading = false
        switch result {
        case .success(let snapshot):
            self.snapshot = snapshot
            error = nil
        case .failure(let failure):
            error = failure.localizedDescription
        }
    }
}
