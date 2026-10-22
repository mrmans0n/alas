import Foundation
import Testing
@testable import AlasPlatform

struct ComputerUseDriverLockTests {
    private func lockURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-cu-lock-\(UUID().uuidString)")
            .appendingPathComponent("computer-use.lock")
    }

    @Test func secondAcquireIsRefusedWithHoldersLabelUntilReleased() throws {
        let url = lockURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = try ComputerUseDriverLock.acquire(at: url, label: "Claude · Safari")

        #expect(throws: ComputerUseDriverLock.Refusal.held(label: "Claude · Safari")) {
            _ = try ComputerUseDriverLock.acquire(at: url, label: "Codex")
        }

        first.release()
        let second = try ComputerUseDriverLock.acquire(at: url, label: "Codex")
        second.release()
    }

    @Test func releaseIsIdempotent() throws {
        let url = lockURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = try ComputerUseDriverLock.acquire(at: url, label: "a")
        first.release()
        first.release()
        let second = try ComputerUseDriverLock.acquire(at: url, label: "b")
        first.release()  // must not unlock the second holder's lock
        #expect(throws: ComputerUseDriverLock.Refusal.held(label: "b")) {
            _ = try ComputerUseDriverLock.acquire(at: url, label: "c")
        }
        second.release()
    }
}
