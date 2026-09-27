import Darwin
import Foundation
import Testing
@testable import Alas

struct LocalTextModelLeaseTests {
    @Test func readerExcludesIndependentWriterAndKeepsStableLock() async throws {
        let fixture = try LocalTextModelFixture.verifiedInstall()
        defer { fixture.removeTemporaryRoot() }
        let lease = try await fixture.store.acquireVerifiedLease()
        let before = try FileManager.default.attributesOfItem(atPath: fixture.root.appendingPathComponent(".lock").path)[.systemFileNumber] as? NSNumber
        let other = LocalTextModelStore(root: fixture.root, manifest: fixture.manifest, transport: fixture.transport)
        await #expect(throws: LocalTextModelFailure.busy) { try await other.remove() }
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
        let fixture = try LocalTextModelFixture.verifiedInstall()
        defer { fixture.removeTemporaryRoot() }
        let lease = try await fixture.store.acquireVerifiedLease()
        lease.close()
        let process = Process()
        // Perl is a plain binary; /usr/bin/python3 is an xcrun shim that
        // resolves a toolchain first.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", """
        use Fcntl qw(:DEFAULT :flock);
        $| = 1;
        sysopen(my $f, $ARGV[0], O_RDWR | O_NOFOLLOW) or die "open: $!";
        flock($f, LOCK_SH | LOCK_NB) or die "lock: $!";
        print "R\\n"; sysread(STDIN, my $b, 1);
        flock($f, LOCK_UN) or die "unlock: $!";
        print "U\\n"; sysread(STDIN, $b, 1);
        flock($f, LOCK_SH | LOCK_NB) or die "relock: $!";
        print "R\\n"; sysread(STDIN, $b, 1);
        close($f);
        """, fixture.root.appendingPathComponent(".lock").path]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        // Without the parent's write ends, a child that exits early gives the
        // reads below EOF instead of blocking them until the time limit.
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
                let cleanupDeadline = ContinuousClock.now.advanced(by: .seconds(2))
                while process.isRunning, ContinuousClock.now < cleanupDeadline { _ = sched_yield() }
            }
            if !process.isRunning { process.waitUntilExit() }
        }
        func expectResponse(_ expected: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
            let actual = String(decoding: try output.fileHandleForReading.read(upToCount: 2) ?? Data(), as: UTF8.self)
            guard actual != expected else { return }
            // An empty reply means the child exited, so its stderr is complete.
            let childErrors = actual.isEmpty ? String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) : ""
            Issue.record("Lock holder replied \(actual.debugDescription), expected \(expected.debugDescription). \(childErrors)",
                         sourceLocation: sourceLocation)
        }
        try expectResponse("R\n")
        await #expect(throws: LocalTextModelFailure.busy) { try await fixture.store.remove() }
        await fixture.store.install()
        #expect(await fixture.store.state == .failed(.busy))
        try input.fileHandleForWriting.write(contentsOf: Data([1]))
        try expectResponse("U\n")
        try await fixture.store.remove()
        try input.fileHandleForWriting.write(contentsOf: Data([1]))
        try expectResponse("R\n")
        await fixture.store.install()
        #expect(await fixture.store.state == .failed(.busy))
        await #expect(throws: LocalTextModelFailure.busy) { try await fixture.store.remove() }
        try input.fileHandleForWriting.write(contentsOf: Data([1]))
        try input.fileHandleForWriting.close()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while process.isRunning, ContinuousClock.now < deadline { await Task.yield() }
        try #require(!process.isRunning)
        #expect(process.terminationStatus == 0)
        fixture.transport.mode.withLock { $0 = .valid }
        await fixture.store.install()
        #expect(await fixture.store.state == .ready)
        try await fixture.store.remove()
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("unrelated"), encoding: .utf8) == "keep")
    }
}
