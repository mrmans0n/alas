import Darwin
import Foundation
import Testing
@testable import Alas

struct NextPromptModelLeaseTests {
    @Test func readerExcludesIndependentWriterAndKeepsStableLock() async throws {
        let fixture = try ModelStoreFixture.verifiedInstall()
        defer { fixture.removeTemporaryRoot() }
        let lease = try await fixture.store.acquireVerifiedLease()
        let before = try FileManager.default.attributesOfItem(atPath: fixture.root.appendingPathComponent(".lock").path)[.systemFileNumber] as? NSNumber
        let other = NextPromptModelStore(root: fixture.root, manifest: fixture.manifest, transport: fixture.transport)
        await #expect(throws: NextPromptModelFailure.busy) { try await other.remove() }
        await other.install()
        #expect(await other.state == .failed(.busy))
        lease.close()
        lease.close()
        try await other.remove()
        let after = try FileManager.default.attributesOfItem(atPath: fixture.root.appendingPathComponent(".lock").path)[.systemFileNumber] as? NSNumber
        #expect(before == after)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("unrelated"), encoding: .utf8) == "keep")
    }

    @Test func childProcessRetainsOriginalLockAcrossRemoveAndRetry() async throws {
        let fixture = try ModelStoreFixture.verifiedInstall()
        defer { fixture.removeTemporaryRoot() }
        let lease = try await fixture.store.acquireVerifiedLease()
        lease.close()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
        import os,fcntl,sys
        f=os.open(sys.argv[1],os.O_RDWR|os.O_NOFOLLOW)
        fcntl.flock(f,fcntl.LOCK_SH|fcntl.LOCK_NB)
        print('R',flush=True)
        sys.stdin.buffer.read(1)
        fcntl.flock(f,fcntl.LOCK_UN)
        print('U',flush=True)
        sys.stdin.buffer.read(1)
        fcntl.flock(f,fcntl.LOCK_SH|fcntl.LOCK_NB)
        print('R',flush=True)
        sys.stdin.buffer.read(1)
        os.close(f)
        """, fixture.root.appendingPathComponent(".lock").path]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        func response() throws -> String {
            String(data: try output.fileHandleForReading.read(upToCount: 2) ?? Data(), encoding: .utf8) ?? ""
        }
        #expect(try response() == "R\n")
        await #expect(throws: NextPromptModelFailure.busy) { try await fixture.store.remove() }
        await fixture.store.install()
        #expect(await fixture.store.state == .failed(.busy))
        try input.fileHandleForWriting.write(contentsOf: Data([1]))
        #expect(try response() == "U\n")
        try await fixture.store.remove()
        try input.fileHandleForWriting.write(contentsOf: Data([1]))
        #expect(try response() == "R\n")
        await fixture.store.install()
        #expect(await fixture.store.state == .failed(.busy))
        await #expect(throws: NextPromptModelFailure.busy) { try await fixture.store.remove() }
        try input.fileHandleForWriting.write(contentsOf: Data([1]))
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        fixture.transport.mode.withLock { $0 = .valid }
        await fixture.store.install()
        #expect(await fixture.store.state == .ready)
        try await fixture.store.remove()
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("unrelated"), encoding: .utf8) == "keep")
    }
}
