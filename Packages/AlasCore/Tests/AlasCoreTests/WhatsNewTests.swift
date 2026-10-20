import Foundation
import Testing

@testable import AlasCore

struct WhatsNewTests {
    private func makeDirectory(_ files: [String: String], mediaFiles: [String] = []) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("whats-new-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("entries", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, content) in files {
            try content.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        for media in mediaFiles {
            let url = dir.appendingPathComponent(media)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        return dir
    }

    private static func entryJSON(
        version: String = "0.22.0", title: String = "T", body: String = "B",
        extra: String = "", headlineExtra: String = ""
    ) -> String {
        """
        {"version": "\(version)", "headline": {"title": "\(title)", "body": "\(body)"\(headlineExtra)}\(extra)}
        """
    }

    private func version(_ raw: String) -> SemanticVersion { SemanticVersion(parsing: raw)! }

    @Test func loadsAValidEntryWithOptionalFieldsMissing() throws {
        let dir = try makeDirectory(["0.22.0.json": Self.entryJSON(version: "0.22.0")])
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let catalog = WhatsNewCatalog.load(directory: dir)
        #expect(catalog.entries.count == 1)
        #expect(catalog.entries.first?.also == [])
        #expect(catalog.entries.first?.headline.action == nil)
        #expect(catalog.problems.isEmpty)
    }

    @Test func headerAndReleaseNotesUseTheEntryVersion() throws {
        let dir = try makeDirectory(["0.22.1.json": Self.entryJSON(version: "0.22.1")])
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let entry = try #require(WhatsNewCatalog.load(directory: dir).entries.first)
        #expect(entry.headerTitle == "New in 0.22")
        #expect(
            entry.releaseNotesURL.absoluteString
                == "https://github.com/mrmans0n/alas/releases/tag/v0.22.1")
    }

    struct InvalidCase: Sendable, CustomTestStringConvertible {
        let name: String
        let json: String
        let messageFragment: String
        /// File to create relative to the entries directory before loading.
        var extraFile: String? = nil
        var testDescription: String { name }
    }

    static let invalidCases: [InvalidCase] = [
        InvalidCase(name: "filename mismatch", json: entryJSON(version: "0.22.1"), messageFragment: "does not match"),
        InvalidCase(name: "missing media", json: entryJSON(headlineExtra: ", \"media\": \"media/missing.gif\""), messageFragment: "does not exist"),
        InvalidCase(
            name: "relative escape", json: entryJSON(headlineExtra: ", \"media\": \"../escape.gif\""),
            messageFragment: "escapes", extraFile: "../escape.gif"),
        InvalidCase(name: "absolute path", json: entryJSON(headlineExtra: ", \"media\": \"/tmp/x.gif\""), messageFragment: "relative"),
        InvalidCase(name: "unknown action", json: entryJSON(headlineExtra: ", \"action\": \"launchMissiles\""), messageFragment: "decode"),
        InvalidCase(
            name: "too many also",
            json: entryJSON(extra: ", \"also\": [{\"title\":\"a\"},{\"title\":\"b\"},{\"title\":\"c\"}]"),
            messageFragment: "also"),
        InvalidCase(name: "malformed JSON", json: "{ not json", messageFragment: "decode"),
        InvalidCase(name: "blank title", json: entryJSON(title: "  "), messageFragment: "title"),
        InvalidCase(name: "blank body", json: entryJSON(body: " "), messageFragment: "body"),
    ]

    @Test(arguments: invalidCases) func rejectsInvalidEntries(_ testCase: InvalidCase) throws {
        let dir = try makeDirectory(["0.22.0.json": testCase.json], mediaFiles: [])
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        if let extra = testCase.extraFile {
            let url = dir.appendingPathComponent(extra).standardizedFileURL
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        let catalog = WhatsNewCatalog.load(directory: dir)
        #expect(catalog.entries.isEmpty)
        #expect(catalog.problems.count == 1)
        #expect(catalog.problems.first?.file == "0.22.0.json")
        #expect(catalog.problems.first?.message.contains(testCase.messageFragment) == true)
    }

    @Test func keepsValidEntriesWhenAnotherIsBroken() throws {
        let dir = try makeDirectory([
            "0.21.0.json": Self.entryJSON(version: "0.21.0"),
            "0.22.0.json": "{ broken",
        ])
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let catalog = WhatsNewCatalog.load(directory: dir)
        #expect(catalog.entries.map(\.version) == [version("0.21.0")])
        #expect(catalog.problems.count == 1)
    }

    @Test func ignoresNonJSONFilesAndMediaFolder() throws {
        let dir = try makeDirectory(
            ["README.md": "hi", "0.22.0.json": Self.entryJSON(version: "0.22.0")],
            mediaFiles: ["media/a.gif"])
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let catalog = WhatsNewCatalog.load(directory: dir)
        #expect(catalog.entries.count == 1)
        #expect(catalog.problems.isEmpty)
    }

    // MARK: - Policy

    private static func v(_ raw: String) -> SemanticVersion { SemanticVersion(parsing: raw)! }

    private static let fixtureEntries: [WhatsNewEntry] = ["0.21.0", "0.22.0", "0.23.0"].map {
        WhatsNewEntry(version: v($0), headline: WhatsNewHeadline(title: "T", body: "B"))
    }

    struct LaunchCase: Sendable, CustomTestStringConvertible {
        let name: String
        let track: ReleaseTrack
        let current: String
        let lastSeen: String?
        let existing: Bool
        let expectedEntry: String?
        let expectedStore: String?
        var testDescription: String { name }
    }

    static let launchCases: [LaunchCase] = [
        LaunchCase(name: "fresh install", track: .stable, current: "0.22.0", lastSeen: nil, existing: false, expectedEntry: nil, expectedStore: "0.22.0"),
        LaunchCase(name: "existing user, first release with feature", track: .stable, current: "0.22.0", lastSeen: nil, existing: true, expectedEntry: "0.22.0", expectedStore: nil),
        LaunchCase(name: "existing user, no entry for current", track: .stable, current: "0.22.1", lastSeen: nil, existing: true, expectedEntry: nil, expectedStore: "0.22.1"),
        LaunchCase(name: "update with entry", track: .stable, current: "0.22.0", lastSeen: "0.21.0", existing: true, expectedEntry: "0.22.0", expectedStore: nil),
        LaunchCase(name: "multi-version jump fills from skipped", track: .stable, current: "0.22.1", lastSeen: "0.21.5", existing: true, expectedEntry: "0.22.0", expectedStore: nil),
        LaunchCase(name: "update without entry in range", track: .stable, current: "0.21.3", lastSeen: "0.21.0", existing: true, expectedEntry: nil, expectedStore: "0.21.3"),
        LaunchCase(name: "entry newer than build ignored", track: .stable, current: "0.22.5", lastSeen: "0.22.0", existing: true, expectedEntry: nil, expectedStore: "0.22.5"),
        LaunchCase(name: "same version", track: .stable, current: "0.22.0", lastSeen: "0.22.0", existing: true, expectedEntry: nil, expectedStore: nil),
        LaunchCase(name: "downgrade", track: .stable, current: "0.21.0", lastSeen: "0.22.0", existing: true, expectedEntry: nil, expectedStore: nil),
        LaunchCase(name: "nightly", track: .nightly, current: "0.22.0", lastSeen: "0.21.0", existing: true, expectedEntry: nil, expectedStore: nil),
    ]

    @Test(arguments: launchCases) func launchDecision(_ c: LaunchCase) {
        let decision = WhatsNewPolicy.onLaunch(
            track: c.track, current: Self.v(c.current), lastSeen: c.lastSeen.map(Self.v),
            isExistingInstall: c.existing, entries: Self.fixtureEntries)
        #expect(decision.entry?.version == c.expectedEntry.map(Self.v))
        #expect(decision.seenVersionToStore == c.expectedStore.map(Self.v))
    }

    @Test func dismissNeverLowersTheSeenVersion() {
        let high = Self.v("0.22.0")
        #expect(WhatsNewPolicy.seenVersionAfterDismiss(current: Self.v("0.21.0"), lastSeen: high) == high)
        #expect(WhatsNewPolicy.seenVersionAfterDismiss(current: high, lastSeen: Self.v("0.21.0")) == high)
        #expect(WhatsNewPolicy.seenVersionAfterDismiss(current: high, lastSeen: nil) == high)
    }

    @Test func helpMenuSkipsEntriesNewerThanTheBuild() {
        #expect(
            WhatsNewPolicy.latestEntry(current: Self.v("0.22.4"), entries: Self.fixtureEntries)?.version
                == Self.v("0.22.0"))
        #expect(WhatsNewPolicy.latestEntry(current: Self.v("0.20.0"), entries: Self.fixtureEntries) == nil)
    }

    @Test func committedEntriesAreValid() throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Alas/Resources/WhatsNew", isDirectory: true)
        var isDirectory: ObjCBool = false
        try #require(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        let catalog = WhatsNewCatalog.load(directory: directory)
        #expect(catalog.problems.isEmpty, "\(catalog.problems)")
    }
}
