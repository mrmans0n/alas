import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACPTerminalHost")
struct ACPTerminalHostTests {
    @Test("create returns a unique terminalId and stores the terminal")
    func createStores() throws {
        let host = ACPTerminalHost(sessionCwd: "/tmp", sessionEnv: [:])
        let p = ACPTerminalCreateParams(
            sessionId: "s", command: "/bin/echo",
            args: ["x"], env: nil, cwd: nil, outputByteLimit: nil)
        let r1 = try host.create(p)
        let r2 = try host.create(p)
        #expect(r1.terminalId != r2.terminalId)
        #expect(host.terminal(id: r1.terminalId) != nil)
    }

    @Test("output on unknown id throws 'terminal not found'")
    func unknownOutput() {
        let host = ACPTerminalHost(sessionCwd: "/tmp", sessionEnv: [:])
        let p = ACPTerminalOutputParams(sessionId: "s", terminalId: "nope")
        #expect(throws: ACPTerminalHostError.notFound("nope")) {
            _ = try host.output(p)
        }
    }

    @Test("release retains the entry but invalidates the id for protocol calls")
    func releaseRetainsForUI() async throws {
        let host = ACPTerminalHost(sessionCwd: "/tmp", sessionEnv: [:])
        let p = ACPTerminalCreateParams(
            sessionId: "s", command: "/bin/echo",
            args: ["y"], env: nil, cwd: nil, outputByteLimit: nil)
        let r = try host.create(p)
        // Let echo finish so the buffer has something to retain.
        if let term = host.terminal(id: r.terminalId) { _ = await term.waitForExit() }

        try host.release(.init(sessionId: "s", terminalId: r.terminalId))

        // UI lookup still returns the terminal so the tool card keeps rendering.
        let retained = host.terminal(id: r.terminalId)
        #expect(retained != nil)
        #expect(retained?.released == true)
        #expect(retained?.snapshot(byteLimit: 1024).text.contains("y") == true)

        // Protocol methods reject the released id with notFound.
        #expect(throws: ACPTerminalHostError.notFound(r.terminalId)) {
            _ = try host.output(.init(sessionId: "s", terminalId: r.terminalId))
        }
        #expect(throws: ACPTerminalHostError.notFound(r.terminalId)) {
            try host.kill(.init(sessionId: "s", terminalId: r.terminalId))
        }
        #expect(throws: ACPTerminalHostError.notFound(r.terminalId)) {
            try host.release(.init(sessionId: "s", terminalId: r.terminalId))
        }
    }

    @Test("releasing a live terminal still publishes exitStatus")
    func releaseLiveStillFinalizes() async throws {
        // Releasing a running command kills it. The terminal must still
        // finalize (`exitStatus` published) so it stops counting as live
        // against maxLiveTerminals — otherwise repeated releases starve
        // future `terminal/create` calls.
        let host = ACPTerminalHost(sessionCwd: "/tmp", sessionEnv: [:])
        let r = try host.create(.init(
            sessionId: "s", command: "/bin/sleep",
            args: ["60"], env: nil, cwd: nil, outputByteLimit: nil))
        let term = host.terminal(id: r.terminalId)
        #expect(term != nil)
        try host.release(.init(sessionId: "s", terminalId: r.terminalId))
        let status = await term!.waitForExit()
        #expect(status.signal != nil || (status.exitCode ?? 0) != 0)
        // The released entry no longer counts as live, so we can create
        // up to the cap fresh.
        let live = host.terminal(id: r.terminalId)?.exitStatus
        #expect(live != nil)
    }

    @Test("waitForExit result encodes {exitCode, signal} at the top level")
    func waitForExitWireShape() async throws {
        let host = ACPTerminalHost(sessionCwd: "/tmp", sessionEnv: [:])
        let r = try host.create(.init(
            sessionId: "s", command: "/bin/sh",
            args: ["-c", "exit 0"], env: nil, cwd: nil, outputByteLimit: nil))
        let status = try await host.waitForExit(.init(sessionId: "s", terminalId: r.terminalId))
        let json = try JSONEncoder().encode(status)
        let obj = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        // Per ACP spec WaitForTerminalExitResponse: exitCode and signal sit
        // at the top level — there must be no `exitStatus` wrapper key.
        #expect(obj?["exitCode"] as? Int == 0)
        #expect(obj?.keys.contains("exitStatus") == false)
    }

    @Test("killAll terminates every live terminal")
    func killAllTerminates() async throws {
        let host = ACPTerminalHost(sessionCwd: "/tmp", sessionEnv: [:])
        let p = ACPTerminalCreateParams(
            sessionId: "s", command: "/bin/sleep",
            args: ["60"], env: nil, cwd: nil, outputByteLimit: nil)
        let r = try host.create(p)
        host.killAll()
        // The terminal should observe exit shortly.
        let term = host.terminal(id: r.terminalId)
        #expect(term != nil)
        let status = await term!.waitForExit()
        #expect(status.exitCode != 0 || status.signal != nil)
    }

    @Test("create errors after 32 live terminals")
    func tooManyLive() async throws {
        let host = ACPTerminalHost(sessionCwd: "/tmp", sessionEnv: [:])
        var ids: [String] = []
        for _ in 0 ..< 32 {
            let p = ACPTerminalCreateParams(
                sessionId: "s", command: "/bin/sleep",
                args: ["60"], env: nil, cwd: nil, outputByteLimit: nil)
            ids.append(try host.create(p).terminalId)
        }
        let p = ACPTerminalCreateParams(
            sessionId: "s", command: "/bin/echo",
            args: ["x"], env: nil, cwd: nil, outputByteLimit: nil)
        #expect(throws: ACPTerminalHostError.tooManyTerminals) {
            _ = try host.create(p)
        }
        host.killAll()
        // Wait for every spawned terminal to actually exit so we don't
        // leak 32 `sleep 60` processes when the suite is run on CI.
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                if let term = host.terminal(id: id) {
                    group.addTask { _ = await term.waitForExit() }
                }
            }
        }
    }
}
