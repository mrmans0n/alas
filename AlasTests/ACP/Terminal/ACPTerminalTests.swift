import Darwin
import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACPTerminal")
struct ACPTerminalTests {
    @Test("echo captures stdout and reports exit 0")
    func captureEcho() async throws {
        let t = try ACPTerminal(
            id: "t1",
            command: "/bin/echo",
            args: ["hello"],
            env: [:],
            cwd: "/tmp",
            outputByteLimit: 1024
        )
        let status = await t.waitForExit()
        #expect(status.exitCode == 0)
        let snap = t.snapshot(byteLimit: 1024)
        #expect(snap.text.contains("hello"))
        #expect(snap.truncated == false)
    }

    @Test("non-zero exit code is captured")
    func nonZeroExit() async throws {
        let t = try ACPTerminal(
            id: "t2",
            command: "/bin/sh",
            args: ["-c", "exit 7"],
            env: [:],
            cwd: "/tmp",
            outputByteLimit: 1024
        )
        let status = await t.waitForExit()
        #expect(status.exitCode == 7)
    }

    @Test("snapshot after waitForExit on a fast command sees the full output")
    func fastExitOutputDrained() async throws {
        // Repeatedly run a short-lived `echo` and verify wait_for_exit
        // returns ONLY after the output has landed in the buffer. The
        // race Codex flagged: terminationHandler resumes waiters before
        // the readability handler's dispatched appendChunk Task runs.
        for i in 0..<20 {
            let t = try ACPTerminal(
                id: "tfast-\(i)",
                command: "/bin/echo",
                args: ["mark-\(i)"],
                env: [:],
                cwd: "/tmp",
                outputByteLimit: 1024
            )
            _ = await t.waitForExit()
            let snap = t.snapshot(byteLimit: 1024).text
            #expect(snap.contains("mark-\(i)"))
        }
    }

    @Test("release reaches a backgrounded descendant after root exited")
    func releaseReachesOrphans() async throws {
        // Backgrounded sleep inherits the pipe write end, so the root
        // can exit but the EOF on our read end never fires. The parent
        // stays alive for ~3 s after the fork so the periodic
        // descendant tracker can capture the BG sleep before exit; once
        // the root exits, kill() relies on that captured set to reach
        // the orphan and let EOF finally arrive.
        let t = try ACPTerminal(
            id: "torphan",
            command: "/bin/sh",
            args: ["-c", "sleep 60 & echo $!; sleep 3"],
            env: [:],
            cwd: "/tmp",
            outputByteLimit: 1024
        )
        var sleepPid: pid_t = 0
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 40_000_000)
            let snap = t.snapshot(byteLimit: 1024).text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let pid = pid_t(snap) {
                sleepPid = pid
                break
            }
        }
        #expect(sleepPid != 0)
        // Wait long enough for sh to finish its `sleep 3` and exit, so
        // we're genuinely in the orphaned-pipe state when release runs.
        try await Task.sleep(nanoseconds: 3_500_000_000)
        #expect(t.exitStatus == nil)
        t.release()
        _ = await t.waitForExit()
        var reaped = false
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 40_000_000)
            if Darwin.kill(sleepPid, 0) != 0 {
                reaped = true
                break
            }
        }
        #expect(reaped)
    }

    @Test("kill escalates to SIGKILL when a descendant traps SIGTERM")
    func killEscalatesToSigkill() async throws {
        // Shell forks a SIGTERM-trapping sleep, prints its PID, waits.
        // The root shell exits on SIGTERM, but the trapped child should
        // survive SIGTERM and only die at the 2 s SIGKILL escalation.
        let t = try ACPTerminal(
            id: "ttrap",
            command: "/bin/sh",
            args: ["-c", "(trap '' TERM; sleep 30) & echo $! ; wait"],
            env: [:],
            cwd: "/tmp",
            outputByteLimit: 1024
        )
        var trappedPid: pid_t = 0
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 40_000_000)
            let snap = t.snapshot(byteLimit: 1024).text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let pid = pid_t(snap) {
                trappedPid = pid
                break
            }
        }
        #expect(trappedPid != 0)
        t.kill()
        _ = await t.waitForExit()
        // Poll up to ~4 s for the trapped child to die under SIGKILL.
        var reaped = false
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 40_000_000)
            if Darwin.kill(trappedPid, 0) != 0 {
                reaped = true
                break
            }
        }
        #expect(reaped)
    }

    @Test("kill terminates the whole process group")
    func killReachesGrandchildren() async throws {
        // Shell forks a `sleep 30` background child, prints its PID,
        // then waits. After we kill the shell's process group, the
        // grandchild sleep should also exit — verified by polling
        // kill(grandchildPid, 0) until it returns ESRCH.
        let t = try ACPTerminal(
            id: "tpgkill",
            command: "/bin/sh",
            args: ["-c", "sleep 30 & echo $! ; wait"],
            env: [:],
            cwd: "/tmp",
            outputByteLimit: 1024
        )
        // Wait until the shell has printed the grandchild PID.
        var grandchildPid: pid_t = 0
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 40_000_000)
            let snap = t.snapshot(byteLimit: 1024).text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let pid = pid_t(snap) {
                grandchildPid = pid
                break
            }
        }
        #expect(grandchildPid != 0)
        t.kill()
        _ = await t.waitForExit()
        // Poll for grandchild death — SIGTERM → process group → child.
        var reaped = false
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 40_000_000)
            if Darwin.kill(grandchildPid, 0) != 0 {
                reaped = true
                break
            }
        }
        #expect(reaped)
    }

    @Test("kill terminates a long-running process within 3 s")
    func killTerminates() async throws {
        let t = try ACPTerminal(
            id: "t3",
            command: "/bin/sleep",
            args: ["60"],
            env: [:],
            cwd: "/tmp",
            outputByteLimit: 1024
        )
        defer { t.release() }
        // Give the process a moment to actually start.
        try await Task.sleep(nanoseconds: 100_000_000)
        t.kill()
        let start = Date()
        let status = await t.waitForExit()
        #expect(Date().timeIntervalSince(start) < 3.0)
        // Foundation reports termination by signal; we just want NOT zero-exit-success.
        #expect(status.signal != nil || (status.exitCode ?? 0) != 0)
    }

    @Test("snapshot honors a sub-1024 outputByteLimit")
    func smallByteLimit() async throws {
        let t = try ACPTerminal(
            id: "tsmall",
            command: "/bin/sh",
            args: ["-c", "printf 'abcdefghij'"],
            env: [:],
            cwd: "/tmp",
            outputByteLimit: 4
        )
        _ = await t.waitForExit()
        let snap = t.snapshot(byteLimit: 4)
        #expect(snap.text.count == 4)
        #expect(snap.truncated == true)
        #expect(snap.text == "ghij")
    }

    @Test("snapshot lookback resyncs into a cut ANSI escape")
    func snapshotResyncsEscape() async throws {
        // Output is `prefix\u{1B}[31mHELLO`; cut at limit=8 lands
        // mid-CSI (suffix would start at `m`/`HELLO` or earlier).
        // The lookback must extend the slice start back to the ESC
        // so the parser strips the escape instead of emitting `mHELLO`
        // or similar garbage. Resulting text must be a clean `HELLO`
        // with no escape fragments.
        let t = try ACPTerminal(
            id: "tcut",
            command: "/bin/sh",
            args: ["-c", "printf 'prefix\\033[31mHELLO'"],
            env: [:],
            cwd: "/tmp",
            outputByteLimit: 8
        )
        _ = await t.waitForExit()
        let snap = t.snapshot(byteLimit: 8)
        #expect(snap.truncated == true)
        #expect(snap.text == "HELLO")
    }

    @Test("snapshot tail starts at a UTF-8 codepoint boundary")
    func snapshotUTF8Boundary() async throws {
        // 4 × 🎉 = 16 bytes (each 4 bytes). Limit to 9: naive byte
        // suffix would start with two continuation bytes of the second
        // codepoint and corrupt the decode. The fix advances past them.
        let t = try ACPTerminal(
            id: "tutf",
            command: "/bin/sh",
            args: ["-c", "printf '🎉🎉🎉🎉'"],
            env: [:],
            cwd: "/tmp",
            outputByteLimit: 9
        )
        _ = await t.waitForExit()
        let snap = t.snapshot(byteLimit: 9)
        // We expect 2 complete 🎉 (8 bytes) — never a replacement char.
        #expect(!snap.text.contains("\u{FFFD}"))
        #expect(snap.text == "🎉🎉")
        #expect(snap.truncated == true)
    }

    @Test("bare command name resolves through PATH")
    func bareCommandPATH() async throws {
        // `echo` (no leading slash) must spawn via /usr/bin/env so PATH
        // is consulted. Foundation's Process would otherwise fail.
        let t = try ACPTerminal(
            id: "tpath",
            command: "echo",
            args: ["resolved"],
            env: ["PATH": "/bin:/usr/bin"],
            cwd: "/tmp",
            outputByteLimit: 1024
        )
        let status = await t.waitForExit()
        #expect(status.exitCode == 0)
        #expect(t.snapshot(byteLimit: 1024).text.contains("resolved"))
    }

    @Test("rolling-buffer rollover starts on a UTF-8 boundary")
    func rolloverUTF8Boundary() async throws {
        // Emit ~1.6 MiB of 🎉 (4 bytes each) so the 1 MiB rolling cap
        // kicks in and almost certainly trims mid-codepoint. The cap
        // path must advance past any leading continuation bytes, so a
        // full-cap snapshot must contain zero replacement chars.
        let t = try ACPTerminal(
            id: "troll",
            command: "/usr/bin/perl",
            args: ["-e", "print \"\\xf0\\x9f\\x8e\\x89\" x 400000"],
            env: [:],
            cwd: "/tmp",
            outputByteLimit: 1 << 20
        )
        _ = await t.waitForExit()
        let snap = t.snapshot(byteLimit: 1 << 20)
        #expect(snap.truncated == true)
        #expect(!snap.text.contains("\u{FFFD}"))
        // Every retained codepoint should be 🎉.
        #expect(snap.text.unicodeScalars.allSatisfy { $0 == "\u{1F389}" })
    }

    @Test("buffer rolls past 1 MiB and sets truncated sticky")
    func rollingBuffer() async throws {
        let t = try ACPTerminal(
            id: "t4",
            // Print ~1.2 MiB so we exceed the 1 MiB cap.
            command: "/bin/sh",
            args: ["-c", "yes x | head -c 1258291"],
            env: [:],
            cwd: "/tmp",
            outputByteLimit: 2048
        )
        _ = await t.waitForExit()
        let snap = t.snapshot(byteLimit: 2048)
        #expect(snap.truncated == true)
        #expect(snap.text.count <= 2048)
    }
}
