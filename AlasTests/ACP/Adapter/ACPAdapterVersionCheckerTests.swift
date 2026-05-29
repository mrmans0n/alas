import Foundation
import Testing
@testable import Alas

@Suite("ACPAdapterVersionChecker")
struct ACPAdapterVersionCheckerTests {
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

    @Test("runner is invoked with `npm outdated -g <pkg> --json`")
    func passesNpmArgs() async {
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
