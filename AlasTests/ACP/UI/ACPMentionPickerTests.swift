import Foundation
import Testing
@testable import Alas

@Suite("ACP mention picker")
struct ACPMentionPickerTests {
    @Test("ranks fuzzy basename and path matches with shared scorer")
    func ranksFuzzyBasenameAndPathMatches() {
        let root = URL(fileURLWithPath: "/tmp/project")
        let files = [
            root.appendingPathComponent("docs/build-notes.md"),
            root.appendingPathComponent(".github/workflows/build.yml"),
            root.appendingPathComponent(".github/workflows/nightly.yml"),
            root.appendingPathComponent("Sources/ACP/UI/ACPComposer.swift"),
        ]

        let basenameMatches = MentionFuzzy.rank(files: files, query: "byml", limit: 10, relativeTo: root)
        #expect(basenameMatches.first == root.appendingPathComponent(".github/workflows/build.yml"))

        let pathMatches = MentionFuzzy.rank(files: files, query: "aui comp", limit: 10, relativeTo: root)
        #expect(pathMatches.first == root.appendingPathComponent("Sources/ACP/UI/ACPComposer.swift"))
    }

    @Test("keeps directory tokens when candidates share a parent directory")
    func keepsDirectoryTokensWhenCandidatesShareParent() {
        let root = URL(fileURLWithPath: "/tmp/project")
        let files = [
            root.appendingPathComponent("Sources/App.swift"),
            root.appendingPathComponent("Sources/Model.swift"),
        ]

        let matches = MentionFuzzy.rank(files: files, query: "Sources App", limit: 10, relativeTo: root)

        #expect(matches.first == root.appendingPathComponent("Sources/App.swift"))
    }

    @Test("ranks an exact relative path ahead of a scattered fuzzy match")
    func exactRelativePathWins() {
        let root = URL(fileURLWithPath: "/tmp/project")
        let expected = root.appendingPathComponent("ab/cd", isDirectory: true)
        let files = [
            root.appendingPathComponent("A_B/C_D", isDirectory: true),
            expected,
        ]

        let matches = MentionFuzzy.rank(files: files, query: "ab/cd", limit: 10, relativeTo: root)

        #expect(matches.first == expected)
    }

    @Test("deduplicates candidates by relative path and preserves directory URLs")
    func deduplicatesCandidates() {
        let root = URL(fileURLWithPath: "/tmp/project")
        let fileShapedDirectory = root.appendingPathComponent("packages/common/core")
        let directory = root.appendingPathComponent("packages/common/core", isDirectory: true)
        let sibling = root.appendingPathComponent("packages/common/other", isDirectory: true)

        let result = MentionFuzzy.deduplicated(
            files: [fileShapedDirectory, sibling, directory],
            relativeTo: root
        )

        #expect(result == [directory, sibling])
        #expect(result.first?.hasDirectoryPath == true)
    }

    @Test("keyboard navigation stays within the available results")
    func keyboardNavigationClamps() {
        #expect(MentionPickerNavigation.move(from: 0, by: -1, count: 3) == 0)
        #expect(MentionPickerNavigation.move(from: 0, by: 1, count: 3) == 1)
        #expect(MentionPickerNavigation.move(from: 2, by: 1, count: 3) == 2)
        #expect(MentionPickerNavigation.move(from: 0, by: 1, count: 0) == 0)
    }

    @Test("collectFiles includes directories alongside files, flagged as directories")
    func collectFilesIncludesDirectories() throws {
        let root = try makeTempTree([
            "Sources/App.swift",
            "Sources/Model.swift",
            "docs/guide.md",
            ".git/config",
            "node_modules/pkg/index.js",
            ".hidden/secret.txt",
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let collected = MentionFuzzy.collectFiles(under: root, limit: 5000)
        // Canonicalize both sides through resolvingSymlinksInPath so the
        // enumerator's /private-prefixed output and `root` agree before
        // stripping the prefix.
        let rootPath = root.resolvingSymlinksInPath().path
        let relatives = Set(collected.map {
            $0.resolvingSymlinksInPath().path.replacingOccurrences(of: rootPath + "/", with: "")
        })

        // Directories are now pickable entries.
        #expect(relatives.contains("Sources"))
        #expect(relatives.contains("docs"))
        // Their files are still present.
        #expect(relatives.contains("Sources/App.swift"))
        #expect(relatives.contains("docs/guide.md"))
        // Skipped/hidden trees stay excluded — directory and contents alike.
        #expect(!relatives.contains(".git"))
        #expect(!relatives.contains("node_modules"))
        #expect(!relatives.contains(".hidden"))

        // Directory URLs carry the directory designation so the picker can
        // render a folder icon and emit a directory resource link.
        let sourcesDir = try #require(collected.first { $0.lastPathComponent == "Sources" })
        #expect(sourcesDir.hasDirectoryPath)
        let appFile = try #require(collected.first { $0.lastPathComponent == "App.swift" })
        #expect(!appFile.hasDirectoryPath)
    }

    @Test("ancestorDirectories derives every implied directory from file paths")
    func ancestorDirectoriesFromFilePaths() {
        let root = URL(fileURLWithPath: "/tmp/project")
        let paths = [
            "README.md",                       // root file → no directories
            "Sources/App.swift",               // → Sources
            "Sources/ACP/UI/Composer.swift",   // → Sources, Sources/ACP, Sources/ACP/UI
            "build/",                          // untracked dir entry → build
            "docs/api/v1/",                    // nested untracked dir → docs, docs/api, docs/api/v1
        ]

        let dirs = MentionFuzzy.ancestorDirectories(forRelativePaths: paths, root: root)
        let rels = Set(dirs.map { $0.path.replacingOccurrences(of: root.path + "/", with: "") })

        #expect(rels == [
            "Sources", "Sources/ACP", "Sources/ACP/UI",
            "build", "docs", "docs/api", "docs/api/v1",
        ])
        // Every returned URL is flagged as a directory for folder-icon rendering.
        #expect(dirs.allSatisfy { $0.hasDirectoryPath })
    }

    @Test("pickerDirectories surfaces submodule folders despite missing trailing slash")
    func pickerDirectoriesIncludesSubmodules() {
        let root = URL(fileURLWithPath: "/tmp/project")
        // `git ls-files` gives untracked collapsed dirs a trailing slash but
        // emits submodule gitlinks like a file path (no slash) — the caller
        // resolves directory-ness from disk and passes it through.
        let entries: [(path: String, isDirectory: Bool)] = [
            ("README.md", false),
            ("Sources/App.swift", false),
            ("ThirdParty/ghostty", true),   // nested submodule gitlink, no slash
            ("build/", true),               // untracked dir collapsed by git
            ("sub", true),                  // root-level submodule gitlink
        ]

        let dirs = MentionFuzzy.pickerDirectories(forEntries: entries, root: root)
        let rels = Set(dirs.map { $0.path.replacingOccurrences(of: root.path + "/", with: "") })

        #expect(rels == ["Sources", "ThirdParty", "ThirdParty/ghostty", "build", "sub"])
        #expect(dirs.allSatisfy { $0.hasDirectoryPath })
    }

    private func makeTempTree(_ relativeFiles: [String]) throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("mention-picker-\(UUID().uuidString)", isDirectory: true)
        for rel in relativeFiles {
            let fileURL = root.appendingPathComponent(rel)
            try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: fileURL)
        }
        // Resolve symlinks (/var → /private on macOS) so the enumerator's
        // standardized output shares this prefix for relative-path stripping.
        return root.resolvingSymlinksInPath()
    }
}
