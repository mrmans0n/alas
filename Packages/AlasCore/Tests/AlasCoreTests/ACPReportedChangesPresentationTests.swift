import Foundation
import Testing
import AlasCore

struct ACPReportedChangesPresentationTests {
    private static let adapterListCaveat = "This is the adapter's list. Shell commands, generators and background work may have changed other files."
    private static let notCleanCaveat = "This does not mean no files changed. Check Git for the workspace's current state."
    private static let truncationNotice = "The adapter left out some paths."

    private static func reference(_ report: [String: Any]?) throws -> ACPMessage.Attachment {
        guard let report else { return .fileChangeReportReference(requestId: "alas-turn:a") }
        var record = report
        record["version"] = 1
        record["requestId"] = "alas-turn:a"
        let data = try JSONSerialization.data(withJSONObject: record)
        return .fileChangeReportReference(
            requestId: "alas-turn:a", report: try JSONDecoder().decode(ACPAgentFileChangeReport.self, from: data))
    }

    struct PresentationRow: CustomTestStringConvertible, Sendable {
        let testDescription: String
        var hasReference = true
        /// JSON of the report, without `version` and `requestId`.
        var report: String?
        var isTurnActive = false
        let state: ACPReportedChangesPresentation.State?
        var title: String?
        var caveat: String?
        var notice: String?
        var paths: [String] = []
    }

    @Test(arguments: [
        PresentationRow(testDescription: "no reference", hasReference: false, state: nil),
        PresentationRow(testDescription: "awaited during the turn", isTurnActive: true, state: nil),
        PresentationRow(
            testDescription: "missing after the turn", state: .missing, title: "No report received", caveat: notCleanCaveat),
        PresentationRow(
            testDescription: "deduped and sorted",
            report: #"{"status":"reported","paths":["/wt/b","/wt/a","/wt/b"]}"#,
            state: .reported(count: 2), title: "Reported changes · 2", caveat: adapterListCaveat, paths: ["/wt/a", "/wt/b"]),
        PresentationRow(
            testDescription: "an active turn does not hide a landed report",
            report: #"{"status":"reported","paths":["/wt/a"]}"#, isTurnActive: true,
            state: .reported(count: 1), title: "Reported changes · 1", caveat: adapterListCaveat, paths: ["/wt/a"]),
        PresentationRow(
            testDescription: "empty list", report: #"{"status":"reported","paths":[]}"#,
            state: .reportedEmpty, title: "No file changes reported", caveat: adapterListCaveat),
        PresentationRow(
            testDescription: "uncertainty is the caveat",
            report: #"{"status":"reported","paths":["/wt/a"],"uncertainty":"Shell edits are not seen."}"#,
            state: .reported(count: 1), title: "Reported changes · 1", caveat: "Shell edits are not seen.", paths: ["/wt/a"]),
        PresentationRow(
            testDescription: "uncertainty keeps its line breaks, not its spoofing",
            report: #"{"status":"reported","paths":["/wt/a"],"uncertainty":"Seen\u202Eonly\nhere\u0007"}"#,
            state: .reported(count: 1), title: "Reported changes · 1", caveat: "Seen\u{FFFD}only\nhere\u{FFFD}", paths: ["/wt/a"]),
        PresentationRow(
            testDescription: "blank uncertainty falls back",
            report: #"{"status":"reported","paths":["/wt/a"],"uncertainty":" \n"}"#,
            state: .reported(count: 1), title: "Reported changes · 1", caveat: adapterListCaveat, paths: ["/wt/a"]),
        PresentationRow(
            testDescription: "declared complete has no caveat",
            report: #"{"status":"reported","paths":["/wt/a"],"declaredComplete":true}"#,
            state: .reported(count: 1), title: "Reported changes · 1", paths: ["/wt/a"]),
        PresentationRow(
            testDescription: "truncated",
            report: #"{"status":"reported","paths":["/wt/a"],"truncated":true}"#,
            state: .reported(count: 1), title: "Reported changes · 1", caveat: adapterListCaveat,
            notice: truncationNotice, paths: ["/wt/a"]),
        PresentationRow(
            testDescription: "truncated to nothing", report: #"{"status":"reported","paths":[],"truncated":true}"#,
            state: .reportedEmpty, title: "Reported changes · paths omitted", caveat: adapterListCaveat, notice: truncationNotice),
        PresentationRow(
            testDescription: "cancelled", report: #"{"status":"unavailable","reason":"cancelled"}"#,
            state: .unavailable(reasonText: "The turn was cancelled before a report was made."),
            title: "Reported changes unavailable", caveat: notCleanCaveat),
        PresentationRow(
            testDescription: "timeout", report: #"{"status":"unavailable","reason":"timeout"}"#,
            state: .unavailable(reasonText: "The adapter timed out preparing the report."),
            title: "Reported changes unavailable", caveat: notCleanCaveat),
        PresentationRow(
            testDescription: "invalid output", report: #"{"status":"unavailable","reason":"invalidOutput"}"#,
            state: .unavailable(reasonText: "The adapter could not read this turn's changes."),
            title: "Reported changes unavailable", caveat: notCleanCaveat),
        PresentationRow(
            testDescription: "not reported", report: #"{"status":"unavailable","reason":"notReported"}"#,
            state: .unavailable(reasonText: "The adapter does not report changes for this kind of turn."),
            title: "Reported changes unavailable", caveat: notCleanCaveat),
        PresentationRow(
            testDescription: "provider error", report: #"{"status":"unavailable","reason":"providerError"}"#,
            state: .unavailable(reasonText: "The provider failed before a report was made."),
            title: "Reported changes unavailable", caveat: notCleanCaveat),
        PresentationRow(
            testDescription: "unknown reason", report: #"{"status":"unavailable","reason":"somethingNew"}"#,
            state: .unavailable(reasonText: "The adapter gave no report for this turn."),
            title: "Reported changes unavailable", caveat: notCleanCaveat),
        PresentationRow(
            testDescription: "no reason", report: #"{"status":"unavailable"}"#,
            state: .unavailable(reasonText: "The adapter gave no report for this turn."),
            title: "Reported changes unavailable", caveat: notCleanCaveat),
        // A report that says "complete" still cannot make an unavailable turn clean.
        PresentationRow(
            testDescription: "unavailable keeps its caveat when declared complete",
            report: #"{"status":"unavailable","declaredComplete":true}"#,
            state: .unavailable(reasonText: "The adapter gave no report for this turn."),
            title: "Reported changes unavailable", caveat: notCleanCaveat),
    ])
    func reportedChangesPresentation(row: PresentationRow) throws {
        var attachments: [ACPMessage.Attachment] = [.checkpointReference(id: UUID())]
        if row.hasReference {
            let report = try row.report.map { json -> [String: Any] in
                try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            }
            attachments.append(try Self.reference(report))
        }
        let presentation = ACPReportedChangesPresentation.make(attachments: attachments, isTurnActive: row.isTurnActive)
        guard let state = row.state else {
            #expect(presentation == nil)
            return
        }
        let shown = try #require(presentation)
        #expect(shown.state == state)
        #expect(shown.title == row.title)
        #expect(shown.caveat == row.caveat)
        #expect(shown.truncationNotice == row.notice)
        #expect(shown.paths == row.paths)
        #expect(!["Changes", "No changes", "Files changed"].contains(shown.title))
    }

    struct PathRow: CustomTestStringConvertible, Sendable {
        let testDescription: String
        var root = "/wt"
        var physicalRoot: String?
        var memberRoots: [String]?
        let path: String
        /// Nil is `.outside`.
        var file: String?
        /// The `display` when it differs from `file` or the raw path.
        var display: String?
    }

    private static let remoteRoot = RemotePath.virtual(host: "mini", realPath: "/home/me/wt")
    private static let remoteCheckout = RemotePath.virtual(host: "mini", realPath: "/home/me/co")

    @Test(arguments: [
        PathRow(testDescription: "inside", path: "/wt/a/b.swift", file: "a/b.swift"),
        PathRow(testDescription: "rootItself", path: "/wt"),
        PathRow(testDescription: "siblingPrefix", path: "/wt-other/a"),
        PathRow(testDescription: "dotDotEscape", path: "/wt/../etc/passwd"),
        PathRow(testDescription: "dotDotInside", path: "/wt/a/../b", file: "b"),
        PathRow(testDescription: "relative", path: "a/b.swift"),
        PathRow(testDescription: "controlCharacter", path: "/wt/a\nb", display: "/wt/a\u{FFFD}b"),
        PathRow(testDescription: "c1 control character", path: "/wt/a\u{0085}b", display: "/wt/a\u{FFFD}b"),
        PathRow(testDescription: "bidi override on a foreign path", path: "/other/a\u{202E}b", display: "/other/a\u{FFFD}b"),
        PathRow(testDescription: "bidi override stays openable", path: "/wt/a\u{202E}b", file: "a\u{202E}b", display: "a\u{FFFD}b"),
        PathRow(testDescription: "isolate", path: "/wt/a\u{2066}b", file: "a\u{2066}b", display: "a\u{FFFD}b"),
        PathRow(testDescription: "direction mark", path: "/wt/a\u{200F}b", file: "a\u{200F}b", display: "a\u{FFFD}b"),
        PathRow(testDescription: "line separator", path: "/wt/a\u{2028}b", file: "a\u{2028}b", display: "a\u{FFFD}b"),
        PathRow(testDescription: "physicalRoot", root: "/tmp/wt", physicalRoot: "/private/tmp/wt", path: "/private/tmp/wt/a", file: "a"),
        PathRow(testDescription: "privateTmpRoot", root: "/private/tmp/wt", path: "/private/tmp/wt/a", file: "a"),
        PathRow(testDescription: "foreignWithPhysical", root: "/tmp/wt", physicalRoot: "/private/tmp/wt", path: "/private/tmp/other"),
        PathRow(testDescription: "remoteInside", root: remoteRoot, path: "/home/me/wt/a", file: "a"),
        PathRow(testDescription: "remoteForeign", root: remoteRoot, path: "/home/me/other"),
        PathRow(testDescription: "checkoutMember", root: "/co", memberRoots: ["/co/app"], path: "/co/app/a", file: "app/a"),
        PathRow(testDescription: "checkoutNoMember", root: "/co", memberRoots: ["/co/app"], path: "/co/README.md"),
        PathRow(
            testDescription: "checkout reached through its physical root", root: "/tmp/co", physicalRoot: "/private/tmp/co",
            memberRoots: ["/tmp/co/app"], path: "/private/tmp/co/app/a", file: "app/a"),
        PathRow(
            testDescription: "remote checkout member", root: remoteCheckout,
            memberRoots: [RemotePath.virtual(host: "mini", realPath: "/home/me/co/app")], path: "/home/me/co/app/a", file: "app/a"),
    ])
    func reportedPathResolution(row: PathRow) throws {
        let rows = ACPReportedPathResolver.rows(
            for: [row.path], roots: ACPReportedPathRoots(root: row.root, physicalRoot: row.physicalRoot, memberRoots: row.memberRoots))
        let resolved = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(resolved.id == row.path)
        #expect(resolved.target == (row.file.map { .file(relativePath: $0) } ?? .outside))
        #expect(resolved.display == row.display ?? row.file ?? row.path)
    }

    @Test func fileAccessFollowsSymlinksAtClickTime() throws {
        let manager = FileManager.default
        let base = URL(fileURLWithPath: "/tmp/alas-reported-\(UUID().uuidString)")
        let root = base.appendingPathComponent("wt")
        let foreign = base.appendingPathComponent("secrets")
        defer { try? manager.removeItem(at: base) }
        try manager.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try manager.createDirectory(at: foreign, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("src/a"))
        try Data().write(to: foreign.appendingPathComponent("id_rsa"))
        try manager.createSymbolicLink(at: root.appendingPathComponent("docs"), withDestinationURL: foreign)
        try manager.createSymbolicLink(at: root.appendingPathComponent("alias"), withDestinationURL: root.appendingPathComponent("src"))
        try manager.createSymbolicLink(at: root.appendingPathComponent("self"), withDestinationURL: root)

        // Reached through `/tmp`, a symlink itself, as a stored root can be.
        let physicalRoot = try #require(ACPReportedPathRoots.physicalRoot(of: root.path))
        #expect(physicalRoot == "/private" + root.path)
        #expect(ACPReportedPathRoots.physicalRoot(of: root.path + "/self") == physicalRoot)
        #expect(ACPReportedPathRoots.physicalRoot(of: root.path + "/gone") == nil)
        #expect(ACPReportedPathRoots.physicalRoot(of: Self.remoteRoot) == nil)

        let roots = ACPReportedPathRoots(root: root.path, physicalRoot: physicalRoot)
        #expect(roots.access(toFileAt: root.path + "/src/a") == .allowed)
        #expect(roots.access(toFileAt: root.path + "/alias/a") == .allowed)
        #expect(roots.access(toFileAt: root.path + "/docs/id_rsa") == .outside)
        #expect(roots.access(toFileAt: root.path + "/self") == .outside)
        #expect(roots.access(toFileAt: root.path + "/src/gone") == .missing)
        #expect(roots.access(toFileAt: root.path + "/docs/gone") == .missing)

        let unresolved = ACPReportedPathRoots(root: root.path, physicalRoot: nil)
        #expect(unresolved.access(toFileAt: root.path + "/src/a") == .outside)

        // Never probed: the same real path exists nowhere on this machine.
        let remote = ACPReportedPathRoots(root: Self.remoteRoot, physicalRoot: nil)
        #expect(remote.access(toFileAt: Self.remoteRoot + "/a") == .allowed)
    }
}
