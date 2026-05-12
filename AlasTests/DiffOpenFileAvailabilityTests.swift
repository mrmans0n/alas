import Testing
import Foundation
@testable import Alas

struct DiffOpenFileAvailabilityTests {
    @Test func availableForExistingFile() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-test-open-avail-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let file = tmp.appendingPathComponent("hello.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)

        #expect(DiffOpenFileAvailability.isAvailable(worktreePath: tmp, relativePath: "hello.txt"))
    }

    @Test func unavailableForMissingFile() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-test-open-missing-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        #expect(!DiffOpenFileAvailability.isAvailable(worktreePath: tmp, relativePath: "nope.txt"))
    }

    @Test func unavailableForDirectory() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-test-open-dir-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let nested = tmp.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        #expect(!DiffOpenFileAvailability.isAvailable(worktreePath: tmp, relativePath: "Sources"))
    }

    @Test func equatableConformance() {
        #expect(DiffOpenFileAvailability.available == .available)
        #expect(DiffOpenFileAvailability.unavailable(reason: "a") == .unavailable(reason: "a"))
        #expect(DiffOpenFileAvailability.available != .unavailable(reason: ""))
        #expect(DiffOpenFileAvailability.unavailable(reason: "a") != .unavailable(reason: "b"))
    }
}
