import Foundation
import Testing
import AlasCore
@testable import ACP2Qualification

struct QualificationTests {
    @Test(arguments: ["dependency", "symlink"])
    func packageIdentityCoversDependenciesAndRejectsEscapingLinks(change: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("node_modules/dependency"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("node_modules/dependency/index.js")
        try Data("first".utf8).write(to: file)
        let before = try QualificationIdentity.packageDigest(at: root)
        if change == "dependency" {
            try Data("other".utf8).write(to: file)
            #expect(try QualificationIdentity.packageDigest(at: root) != before)
        } else {
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: root.deletingLastPathComponent())
            #expect(throws: (any Error).self) { try QualificationIdentity.packageDigest(at: root) }
        }
    }

    private let directory = URL(fileURLWithPath: "/private/tmp/q-test")
    private let command = "printf ACP_V2_PERMISSION_CHECK > /private/tmp/q-test/permission-probe.txt"

    @Test(arguments: ["exact", "command", "cwd", "unknown", "always", "ambiguous", "extra-permissions"])
    func allowsOnlyTheExpectedOneTimeScratchAction(reason: String) throws {
        let request = try request(reason: reason)
        let selected = QualificationDecisionPolicy.selectOption(in: request, expectedCommand: command, directory: directory, mode: .allowOnce)
        #expect(selected == (reason == "exact" ? "once" : nil))
        let expectedRefusal = ["command": "command", "cwd": "cwd", "unknown": "subject", "always": "options", "ambiguous": "options", "extra-permissions": "input"]
        #expect(QualificationDecisionPolicy.assess(in: request, expectedCommand: command, directory: directory).refusal?.rawValue == expectedRefusal[reason])
    }

    @Test func cancelModeNeverSelectsAnAllowOption() throws {
        #expect(QualificationDecisionPolicy.selectOption(in: try request(reason: "exact"), expectedCommand: command, directory: directory, mode: .cancel) == nil)
    }

    @Test func existingScratchDirectoryMatchesItsPermissionWorkingDirectory() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/apq-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let command = "printf ACP_V2_PERMISSION_CHECK > " + directory.appendingPathComponent("permission-probe.txt").path
        let permission = try request(reason: "exact", directory: directory, command: command)
        #expect(QualificationDecisionPolicy.selectOption(in: permission, expectedCommand: command, directory: directory, mode: .allowOnce) == "once")
    }

    private func request(reason: String, directory: URL? = nil, command: String? = nil) throws -> ACPV2InteractiveRequest {
        let command = command ?? self.command
        let directory = directory ?? self.directory
        var input: [String: Any] = ["command": reason == "command" ? command + "; touch /tmp/unrelated" : command,
                                  "cwd": reason == "cwd" ? "/Users/other" : directory.path]
        if reason == "extra-permissions" { input["additionalPermissions"] = ["network": true] }
        var options: [[String: String]] = [["optionId": "always", "name": "Always", "kind": "allow_always"]]
        if reason != "always" { options.append(["optionId": "once", "name": "Once", "kind": "allow_once"]) }
        if reason == "ambiguous" { options.append(["optionId": "another", "name": "Another", "kind": "allow_once"]) }
        let frame: [String: Any] = ["jsonrpc": "2.0", "id": "permission", "method": "session/request_permission", "params": [
            "sessionId": "s", "title": "Command", "subject": ["type": reason == "unknown" ? "future" : "tool_call",
                "toolCall": ["toolCallId": "t", "kind": "execute", "rawInput": input]], "options": options]]
        return try .decode(frame: JSONSerialization.data(withJSONObject: frame), upstreamSessionId: "s", support: .init())
    }
}
