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

    @Test func recordIDsLeaveTheFileUntouched() throws {
        let (writer, dir) = tempRegistry()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writer.update { $0 = [Self.record("A", owner: Self.other)] }
        let url = dir.appendingPathComponent("registry.json")
        let past = Date(timeIntervalSince1970: 5_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: url.path)
        let before = try Data(contentsOf: url)

        let reader = WorktreeVMRegistry(fileURL: url, isAlive: { _ in false })
        #expect(try reader.recordIDs() == ["A"])
        #expect(try Data(contentsOf: url) == before)
        let modified = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        #expect(modified == past)
    }

    @Test func currentOwnerIsAliveAndBogusStartTimeIsNot() throws {
        let current = try #require(VMRunOwner.current(label: "Alas"))
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

    @Test func unknownRecordsCountAndSurviveUpdatesAndGarbageIsQuarantined() throws {
        let (registry, dir) = tempRegistry()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("registry.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let newer = """
            [{"id":"L","guestOS":"linux","goldenBuild":"x","bundlePath":"/l","createdAt":0,"lastUsedAt":0}]
            """
        try Data(newer.utf8).write(to: file)
        #expect(try registry.recordIDs() == ["L"])

        try registry.update { $0.append(Self.record("A")) }
        #expect(try registry.snapshot().map(\.id) == ["A"])
        let kept = try String(contentsOf: file, encoding: .utf8)
        #expect(kept.contains("\"linux\""))

        try Data("not json {".utf8).write(to: file)
        #expect(try registry.snapshot().isEmpty)
        #expect(try String(contentsOf: file.appendingPathExtension("corrupt"), encoding: .utf8) == "not json {")
    }

    // MARK: - VMBundle

    private static func makeGolden(in root: URL, sealed: Bool) throws -> VMBundle {
        let url = root.appendingPathComponent("golden")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let bundle = VMBundle(url: url)
        try Data("disk-bytes".utf8).write(to: bundle.diskImage)
        try Data("aux-bytes".utf8).write(to: bundle.auxiliaryStorage)
        try Data("hw-bytes".utf8).write(to: bundle.hardwareModel)
        try Data("old-id".utf8).write(to: bundle.machineIdentifier)
        try Data("00:00:00:00:00:00".utf8).write(to: bundle.macAddress)
        if sealed { try Data().write(to: bundle.sealedMarker) }
        return bundle
    }

    private static func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("alas-vm-bundle-\(UUID().uuidString)")
    }

    @Test func cloneRefusesUnsealedGolden() throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let golden = try Self.makeGolden(in: root, sealed: false)
        #expect(throws: (any Error).self) {
            try VMBundle.cloneForWorktree(
                golden: golden, to: root.appendingPathComponent("wt"),
                newMachineIdentifier: Data([1]), newMACAddress: "aa:bb:cc:dd:ee:ff")
        }
    }

    @Test func cloneWritesFreshIdentity() throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let golden = try Self.makeGolden(in: root, sealed: true)
        let clone = try VMBundle.cloneForWorktree(
            golden: golden, to: root.appendingPathComponent("worktrees/wt"),
            newMachineIdentifier: Data([1, 2, 3]), newMACAddress: "aa:bb:cc:dd:ee:ff")

        #expect(try Data(contentsOf: clone.machineIdentifier) == Data([1, 2, 3]))
        #expect(try String(contentsOf: clone.macAddress, encoding: .utf8) == "aa:bb:cc:dd:ee:ff")
        #expect(try Data(contentsOf: clone.diskImage) == Data("disk-bytes".utf8))
        #expect(try Data(contentsOf: clone.auxiliaryStorage) == Data("aux-bytes".utf8))
        #expect(try Data(contentsOf: clone.hardwareModel) == Data("hw-bytes".utf8))
        #expect(!FileManager.default.fileExists(atPath: clone.url.appendingPathExtension("partial").path))
    }

    @Test func failedCloneLeavesNoBundle() throws {
        let root = Self.tempRoot()
        let parent = root.appendingPathComponent("worktrees")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
            try? FileManager.default.removeItem(at: root)
        }
        let golden = try Self.makeGolden(in: root, sealed: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)
        let dest = parent.appendingPathComponent("wt")

        #expect(throws: (any Error).self) {
            try VMBundle.cloneForWorktree(
                golden: golden, to: dest, newMachineIdentifier: Data([1]), newMACAddress: "aa:bb:cc:dd:ee:ff")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
    }
}
