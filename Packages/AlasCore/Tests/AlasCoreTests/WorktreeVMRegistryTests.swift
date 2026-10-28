import Foundation
import Testing
@testable import AlasPlatform

@Suite struct WorktreeVMRegistryTests {
    private static let me = VMRunOwner(pid: 100, processStart: Date(timeIntervalSince1970: 1_000), label: "Alas")
    private static let other = VMRunOwner(pid: 200, processStart: Date(timeIntervalSince1970: 2_000), label: "Alas Dev")

    private static func record(_ id: String, age: TimeInterval = 0, owner: VMRunOwner? = nil) -> WorktreeVMRecord {
        WorktreeVMRecord(
            id: id, goldenBuild: "b1", bundlePath: "/vms/\(id)",
            createdAt: Date(timeIntervalSince1970: 0), lastUsedAt: Date(timeIntervalSince1970: 10_000 - age),
            runOwner: owner)
    }

    private func tempRegistry(
        isAlive: @escaping @Sendable (VMRunOwner) -> Bool = { _ in true }
    ) -> (WorktreeVMRegistry, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("alas-vm-reg-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("registry.json")
        return (WorktreeVMRegistry(fileURL: url, isAlive: isAlive), dir)
    }

    @Test func deadOwnerFreesItsSlot() throws {
        let (registry, dir) = tempRegistry(isAlive: { $0.pid != 200 })
        defer { try? FileManager.default.removeItem(at: dir) }
        try registry.update { $0 = [Self.record("A", owner: Self.other), Self.record("B", owner: Self.me)] }

        let records = try registry.snapshot()
        #expect(records.first { $0.id == "A" }?.runOwner == nil)
        #expect(records.first { $0.id == "B" }?.runOwner == Self.me)
    }

    @Test func currentOwnerIsAliveAndBogusStartTimeIsNot() {
        let current = VMRunOwner.current(label: "Alas")
        #expect(VMRunOwner.isAlive(current))
        var recycled = current
        recycled.processStart = Date(timeIntervalSince1970: 1)
        #expect(!VMRunOwner.isAlive(recycled))
    }

    struct SlotCase: Sendable, CustomTestStringConvertible {
        var name: String
        var records: [WorktreeVMRecord]
        var expected: VMSlotDecision
        var testDescription: String { name }
    }

    @Test(arguments: [
        SlotCase(name: "none running", records: [record("x")], expected: .start),
        SlotCase(
            name: "requester running here", records: [record("x", owner: me)], expected: .alreadyRunningHere),
        SlotCase(
            name: "requester running elsewhere", records: [record("x", owner: other)],
            expected: .runningElsewhere(label: "Alas Dev")),
        SlotCase(
            name: "two running, LRU first",
            records: [
                record("x"), record("newer", age: 10, owner: me), record("older", age: 500, owner: other),
            ],
            expected: .needsUserChoice(candidates: ["older", "newer"])),
        SlotCase(
            name: "one running elsewhere, one free",
            records: [record("x"), record("y", owner: other)], expected: .start),
    ])
    func slotDecision(_ scenario: SlotCase) {
        #expect(VMSlotPolicy.decide(requesting: "x", records: scenario.records, me: Self.me) == scenario.expected)
    }

    @Test func concurrentUpdatesDoNotLoseWrites() async throws {
        let (first, dir) = tempRegistry()
        defer { try? FileManager.default.removeItem(at: dir) }
        let second = WorktreeVMRegistry(fileURL: dir.appendingPathComponent("registry.json"))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (registry, prefix) in [(first, "a"), (second, "b")] {
                for n in 0..<50 {
                    group.addTask { try registry.update { $0.append(Self.record("\(prefix)\(n)")) } }
                }
            }
            try await group.waitForAll()
        }
        #expect(try first.snapshot().count == 100)
    }
}
