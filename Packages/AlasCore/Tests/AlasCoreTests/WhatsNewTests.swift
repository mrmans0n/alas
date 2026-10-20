import Foundation
import Testing

@testable import AlasCore

struct WhatsNewTests {
    private func makeDirectory(_ files: [String: String], mediaFiles: [String] = []) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("whats-new-\(UUID().uuidString)", isDirectory: true)
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

    private func entryJSON(version: String, extra: String = "", headlineExtra: String = "") -> String {
        """
        {"version": "\(version)", "headline": {"title": "T", "body": "B"\(headlineExtra)}\(extra)}
        """
    }

    private func version(_ raw: String) -> SemanticVersion { SemanticVersion(parsing: raw)! }

    @Test func loadsAValidEntryWithOptionalFieldsMissing() throws {
        let dir = try makeDirectory(["0.22.0.json": entryJSON(version: "0.22.0")])
        defer { try? FileManager.default.removeItem(at: dir) }
        let catalog = WhatsNewCatalog.load(directory: dir)
        #expect(catalog.entries.count == 1)
        #expect(catalog.entries.first?.also == [])
        #expect(catalog.entries.first?.headline.action == nil)
        #expect(catalog.problems.isEmpty)
    }

    @Test func headerAndReleaseNotesUseTheEntryVersion() throws {
        let dir = try makeDirectory(["0.22.1.json": entryJSON(version: "0.22.1")])
        defer { try? FileManager.default.removeItem(at: dir) }
        let entry = try #require(WhatsNewCatalog.load(directory: dir).entries.first)
        #expect(entry.headerTitle == "New in 0.22")
        #expect(
            entry.releaseNotesURL.absoluteString
                == "https://github.com/mrmans0n/alas/releases/tag/v0.22.1")
    }

    struct InvalidCase: Sendable, CustomTestStringConvertible {
        let name: String
        let json: String
        var testDescription: String { name }
    }

    static let invalidCases: [InvalidCase] = {
        func json(_ version: String = "0.22.0", headline: String = "", extra: String = "") -> String {
            """
            {"version": "\(version)", "headline": {"title": "T", "body": "B"\(headline)}\(extra)}
            """
        }
        return [
            InvalidCase(name: "filename mismatch", json: json("0.22.1")),
            InvalidCase(name: "missing media", json: json(headline: ", \"media\": \"media/missing.gif\"")),
            InvalidCase(name: "relative escape", json: json(headline: ", \"media\": \"../escape.gif\"")),
            InvalidCase(name: "absolute path", json: json(headline: ", \"media\": \"/tmp/x.gif\"")),
            InvalidCase(name: "unknown action", json: json(headline: ", \"action\": \"launchMissiles\"")),
            InvalidCase(
                name: "too many also",
                json: json(extra: ", \"also\": [{\"title\":\"a\"},{\"title\":\"b\"},{\"title\":\"c\"}]")),
            InvalidCase(name: "malformed JSON", json: "{ not json"),
        ]
    }()

    @Test(arguments: invalidCases) func rejectsInvalidEntries(_ testCase: InvalidCase) throws {
        let dir = try makeDirectory(["0.22.0.json": testCase.json])
        defer { try? FileManager.default.removeItem(at: dir) }
        let catalog = WhatsNewCatalog.load(directory: dir)
        #expect(catalog.entries.isEmpty)
        #expect(catalog.problems.count == 1)
        #expect(catalog.problems.first?.file == "0.22.0.json")
    }

    @Test func keepsValidEntriesWhenAnotherIsBroken() throws {
        let dir = try makeDirectory([
            "0.21.0.json": entryJSON(version: "0.21.0"),
            "0.22.0.json": "{ broken",
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let catalog = WhatsNewCatalog.load(directory: dir)
        #expect(catalog.entries.map(\.version) == [version("0.21.0")])
        #expect(catalog.problems.count == 1)
    }

    @Test func ignoresNonJSONFilesAndMediaFolder() throws {
        let dir = try makeDirectory(
            ["README.md": "hi", "0.22.0.json": entryJSON(version: "0.22.0")],
            mediaFiles: ["media/a.gif"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let catalog = WhatsNewCatalog.load(directory: dir)
        #expect(catalog.entries.count == 1)
        #expect(catalog.problems.isEmpty)
    }
}
