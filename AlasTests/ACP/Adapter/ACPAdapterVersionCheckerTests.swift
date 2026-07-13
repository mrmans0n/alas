import Foundation
import Testing
@testable import Alas

@Suite("ACPAdapterVersionChecker")
struct ACPAdapterVersionCheckerTests {
    private actor RemoteCalls {
        struct Call: Equatable {
            let host: String
            let cwd: String?
            let command: String
            let pathPolicy: SSHCommand.PathPolicy
        }

        private(set) var values: [Call] = []

        func append(_ call: Call) {
            values.append(call)
        }
    }

    private let remoteEnvironment = ACPRemoteNodeEnvironment(
        npmPath: "/opt/node/bin/npm",
        nodePath: "/opt/node/bin/node",
        binDirectory: "/opt/node/bin"
    )

    private func checker(
        status: Int32 = 0,
        stdout: String = "",
        delay: Duration = .zero,
        timeout: TimeInterval = 5
    ) -> ACPAdapterVersionChecker {
        ACPAdapterVersionChecker(
            timeout: timeout,
            runner: { _, _ in
                if delay > .zero { try await Task.sleep(for: delay) }
                return (status: status, stdout: stdout)
            })
    }

    @Test("exit 0 with empty stdout means up to date")
    func upToDateOnEmpty() async {
        let c = checker(status: 0, stdout: "")
        let r = await c.check(packageName: "@x/y")
        #expect(r == .upToDate)
    }

    @Test("exit 1 with current != latest means update available")
    func availableWhenDiffers() async {
        let json = #"{"@x/y":{"current":"1.0.0","wanted":"1.0.0","latest":"1.1.0","dependent":"global"}}"#
        let c = checker(status: 1, stdout: json)
        let r = await c.check(packageName: "@x/y")
        #expect(r == .available(current: "1.0.0", latest: "1.1.0"))
    }

    @Test("exit 1 with current == latest is up to date")
    func upToDateWhenEqual() async {
        let json = #"{"@x/y":{"current":"1.1.0","wanted":"1.1.0","latest":"1.1.0","dependent":"global"}}"#
        let c = checker(status: 1, stdout: json)
        let r = await c.check(packageName: "@x/y")
        #expect(r == .upToDate)
    }

    @Test("prerelease latest is treated as up to date")
    func skipsPrerelease() async {
        let json = #"{"@x/y":{"current":"1.0.0","wanted":"1.0.0","latest":"1.2.0-beta.1","dependent":"global"}}"#
        let c = checker(status: 1, stdout: json)
        let r = await c.check(packageName: "@x/y")
        #expect(r == .upToDate)
    }

    @Test("current newer than latest is up to date")
    func skipsWhenCurrentNewer() async {
        let json = #"{"@x/y":{"current":"2.0.0","wanted":"1.0.0","latest":"1.0.0","dependent":"global"}}"#
        let c = checker(status: 1, stdout: json)
        let r = await c.check(packageName: "@x/y")
        #expect(r == .upToDate)
    }

    @Test("missing current field is up to date (defensive)")
    func missingCurrent() async {
        let json = #"{"@x/y":{"wanted":"1.0.0","latest":"1.1.0","dependent":"global"}}"#
        let c = checker(status: 1, stdout: json)
        let r = await c.check(packageName: "@x/y")
        #expect(r == .upToDate)
    }

    @Test("exit code outside {0,1} is unknown")
    func exitTwoIsUnknown() async {
        let c = checker(status: 2, stdout: "")
        let r = await c.check(packageName: "@x/y")
        #expect(r == .unknown)
    }

    @Test("malformed JSON is unknown")
    func malformedJsonIsUnknown() async {
        let c = checker(status: 1, stdout: "not json {{")
        let r = await c.check(packageName: "@x/y")
        #expect(r == .unknown)
    }

    @Test("JSON without the requested package key but with other shape is unknown")
    func missingPackageEntry() async {
        let json = #"{"other-pkg":{"current":"1.0.0","latest":"1.1.0"}}"#
        let c = checker(status: 1, stdout: json)
        let r = await c.check(packageName: "@x/y")
        #expect(r == .unknown)
    }

    @Test("empty JSON object means up to date")
    func emptyJsonObjectIsUpToDate() async {
        let c = checker(status: 0, stdout: "{}")
        let r = await c.check(packageName: "@x/y")
        #expect(r == .upToDate)
    }

    @Test("npm error payload is unknown, not up to date")
    func errorPayloadIsUnknown() async {
        let json = #"{"error":{"code":"E401","summary":"Unauthorized"}}"#
        let c = checker(status: 1, stdout: json)
        let r = await c.check(packageName: "@x/y")
        #expect(r == .unknown)
    }

    @Test("missing latest field is unknown")
    func missingLatest() async {
        let json = #"{"@x/y":{"current":"1.0.0","wanted":"1.0.0","dependent":"global"}}"#
        let c = checker(status: 1, stdout: json)
        let r = await c.check(packageName: "@x/y")
        #expect(r == .unknown)
    }

    @Test("runner timeout yields unknown")
    func timeoutIsUnknown() async {
        let c = checker(delay: .seconds(5), timeout: 0.1)
        let r = await c.check(packageName: "@x/y")
        #expect(r == .unknown)
    }

    @Test("local runner argv remains exactly `npm outdated -g <pkg> --json`")
    func localArgvIsUnchanged() async {
        var captured: [String] = []
        let c = ACPAdapterVersionChecker(
            timeout: 5,
            runner: { cmd, args in
                captured = [cmd] + args
                return (status: 0, stdout: "")
            })
        _ = await c.check(packageName: "pi-acp")
        #expect(captured == ["npm", "outdated", "-g", "pi-acp", "--json"])
    }

    @Test("remote managed package uses its private prefix and resolved Node environment")
    func remoteManagedPrefixCommand() async {
        let calls = RemoteCalls()
        let json = #"{"@agentclientprotocol/codex-acp":{"current":"1.0.0","latest":"1.1.0"}}"#
        let checker = ACPAdapterVersionChecker(
            remoteRunner: { host, cwd, command, pathPolicy in
                await calls.append(.init(host: host, cwd: cwd, command: command, pathPolicy: pathPolicy))
                let count = await calls.values.count
                return count == 1
                    ? ProcessResult(exitCode: ACPAdapterVersionChecker.managedSourceExitCode, stdout: "", stderr: "")
                    : ProcessResult(exitCode: 1, stdout: json, stderr: "")
            },
            nodeResolver: { _ in remoteEnvironment }
        )

        let result = await checker.check(host: "dev@example", descriptor: .codex)
        let recorded = await calls.values

        #expect(result == .available(current: "1.0.0", latest: "1.1.0"))
        #expect(recorded.count == 2)
        #expect(recorded.allSatisfy { $0.host == "dev@example" && $0.cwd == nil && $0.pathPolicy == .inherited })
        #expect(recorded[0].command.contains("$prefix/lib/node_modules/$package"))
        #expect(recorded[1].command == """
        PATH='/opt/node/bin':"$PATH"
        export PATH
        prefix=$HOME/.alas/acp/codex
        '/opt/node/bin/npm' outdated -g '@agentclientprotocol/codex-acp' --json --prefix "$prefix"
        """)
    }

    @Test("remote absent managed package falls back to the global command")
    func remoteGlobalFallbackCommand() async {
        let calls = RemoteCalls()
        let checker = ACPAdapterVersionChecker(
            remoteRunner: { host, cwd, command, pathPolicy in
                await calls.append(.init(host: host, cwd: cwd, command: command, pathPolicy: pathPolicy))
                let count = await calls.values.count
                return count == 1
                    ? ProcessResult(exitCode: ACPAdapterVersionChecker.globalSourceExitCode, stdout: "", stderr: "")
                    : ProcessResult(exitCode: 0, stdout: "{}", stderr: "")
            },
            nodeResolver: { _ in remoteEnvironment }
        )

        let result = await checker.check(host: "build-host", descriptor: .pi)
        let recorded = await calls.values

        #expect(result == .upToDate)
        #expect(recorded.count == 2)
        #expect(recorded[1].command == """
        PATH='/opt/node/bin':"$PATH"
        export PATH
        '/opt/node/bin/npm' outdated -g 'pi-acp' --json
        """)
    }

    @Test("remote registry failure is unknown")
    func remoteRegistryFailureIsUnknown() async {
        let calls = RemoteCalls()
        let checker = ACPAdapterVersionChecker(
            remoteRunner: { host, cwd, command, pathPolicy in
                await calls.append(.init(host: host, cwd: cwd, command: command, pathPolicy: pathPolicy))
                let count = await calls.values.count
                return count == 1
                    ? ProcessResult(exitCode: ACPAdapterVersionChecker.globalSourceExitCode, stdout: "", stderr: "")
                    : ProcessResult(exitCode: 2, stdout: "", stderr: "registry unavailable")
            },
            nodeResolver: { _ in remoteEnvironment }
        )

        #expect(await checker.check(host: "offline-host", descriptor: .claude) == .unknown)
    }
}

@Suite("AdapterUpdateState Codable")
struct AdapterUpdateStateCodableTests {
    private func roundTrip(_ value: AdapterUpdateState) throws -> AdapterUpdateState {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(AdapterUpdateState.self, from: data)
    }

    @Test("upToDate round-trips")
    func upToDate() throws {
        #expect(try roundTrip(.upToDate) == .upToDate)
    }

    @Test("unknown round-trips")
    func unknown() throws {
        #expect(try roundTrip(.unknown) == .unknown)
    }

    @Test("available round-trips with both versions")
    func available() throws {
        #expect(try roundTrip(.available(current: "1.0.0", latest: "1.1.0"))
                == .available(current: "1.0.0", latest: "1.1.0"))
    }
}
