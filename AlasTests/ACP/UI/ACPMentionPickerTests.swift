import AppKit
import Foundation
import Testing
@testable import Alas

@Suite("ACP mention picker")
struct ACPMentionPickerTests {
    @Test("sessions rank by title before agent or worktree; an empty query shows the most recent")
    func ranksSessions() {
        func session(_ id: String, _ title: String, agent: String = "Codex", worktree: String = "main") -> ACPSessionMentionCandidate {
            .init(id: id, projectId: "p", title: title, agentName: agent, worktreeName: worktree)
        }
        let sessions = [
            session("recent", "Review release notes", worktree: "parser-fix"),
            session("titled", "Fix parser crash"),
            session("other", "Update docs"),
            session("older", "Parser cleanup"),
        ]

        let parser = MentionSessionRanking.rank(sessions, query: "parser").map(\.id)
        #expect(Set(parser.prefix(2)) == ["titled", "older"])
        #expect(parser.last == "recent")
        #expect(MentionSessionRanking.rank(sessions, query: "codex docs").map(\.id) == ["other"])
        #expect(MentionSessionRanking.rank(sessions, query: "", limit: 2).map(\.id) == ["recent", "titled"])
    }

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

    @Test("keeps case-distinct candidates")
    func keepsCaseDistinctCandidates() {
        let root = URL(fileURLWithPath: "/tmp/project")
        let uppercase = root.appendingPathComponent("Sources/Foo.swift")
        let lowercase = root.appendingPathComponent("Sources/foo.swift")

        let result = MentionFuzzy.deduplicated(files: [uppercase, lowercase], relativeTo: root)

        #expect(result == [uppercase, lowercase])
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

    @Test("absolute query lists one directory, folders first, hiding dotfiles until a dot is typed")
    func absoluteQueryBrowsesOneDirectory() throws {
        let root = try makeTempTree(["zeta/inner.txt", "alpha.txt", "beta.md", ".hidden"])
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.path + "/"

        let names = { (query: String) in
            MentionAbsolutePath.entries(forQuery: query, limit: 80).map(\.lastPathComponent)
        }
        #expect(names(dir) == ["zeta", "alpha.txt", "beta.md"])
        #expect(names(dir + "AL") == ["alpha.txt"])
        #expect(names(dir + "eta") == ["zeta", "beta.md"])
        #expect(names(dir + ".") == [".hidden", "alpha.txt", "beta.md"])
        #expect(MentionAbsolutePath.query(entering: root.appendingPathComponent("zeta", isDirectory: true))
            == root.path + "/zeta/")
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

    private func symbol(_ name: String, _ kind: SymbolKind, container: String? = nil, path: String = "Sources/A.swift") -> SymbolEntry {
        SymbolEntry(name: name, kind: kind, container: container, languageID: "swift",
                    relativePath: path, nameRange: NSRange(location: 0, length: name.utf16.count), lineRange: 0...0)
    }

    @Test("symbols rank exact names first, then types over members, real code over tests, shorter paths")
    func ranksSymbols() {
        let symbols = [
            symbol("testRestore", .method, container: "SessionManagerTests", path: "Tests/SessionManagerTests.swift"),
            symbol("restore", .method, container: "TabStore", path: "Sources/Tabs/TabStore.swift"),
            symbol("restore", .method, container: "SessionManager", path: "Sources/SessionManager.swift"),
            symbol("RestorePolicy", .struct, path: "Sources/Session/RestorePolicy.swift"),
            symbol("restore", .method, container: "Fixture", path: "Tests/Fixtures/Fixture.swift"),
        ]
        let ranked = MentionSymbolRanking.rank(symbols, query: "restore", limit: 10).map(\.qualifiedName)
        #expect(ranked == [
            // Equal exact matches: the shorter path wins (27 vs 28 characters).
            "TabStore.restore", "SessionManager.restore", "Fixture.restore",
            "RestorePolicy", "SessionManagerTests.testRestore",
        ])
        #expect(MentionSymbolRanking.rank(symbols, query: "tabst rest", limit: 1).map(\.qualifiedName) == ["TabStore.restore"])
        #expect(MentionSymbolRanking.rank(symbols, query: "zzz", limit: 10).isEmpty)
    }

    @Test("on an equal match, a type beats a member even when the type lives in tests")
    func typeBeatsMember() {
        let symbols = [symbol("Store", .property, container: "App"), symbol("Store", .class, path: "Tests/StoreTests.swift")]
        #expect(MentionSymbolRanking.rank(symbols, query: "Store", limit: 2).map(\.kind) == [.class, .property])
    }

    @Test("test paths follow the spec's directory and file-name rules", arguments: [
        ("Tests/A.swift", true), ("src/__tests__/a.ts", true), ("spec/a_spec.rb", true),
        ("Sources/FooTests.swift", true), ("pkg/server_test.go", true), ("src/a.test.ts", true),
        ("Sources/Testing.swift", false), ("Sources/Contest.swift", false), ("src/latest/a.ts", false),
    ])
    func testPaths(path: String, isTest: Bool) {
        #expect(MentionSymbolRanking.isTestPath(path) == isTest)
    }

    @Test("a # splits a file filter from a symbol filter", arguments: [
        ("restore", MentionSymbolQuery.project("restore")),
        ("TabStore.swift#res", .file(file: "TabStore.swift", symbol: "res")),
        ("TabStore.swift#", .file(file: "TabStore.swift", symbol: "")),
        ("#res", .project("#res")),
        ("a#b#c", .file(file: "a#b", symbol: "c")),
    ])
    func parsesSymbolQuery(query: String, expected: MentionSymbolQuery) {
        #expect(MentionSymbolQuery.parse(query) == expected)
    }

    @Test("File.swift#name lists only that file's symbols, in All as in Symbols")
    func drillDownListsOnlyFileSymbols() {
        for scope in [MentionScope.all, .symbols] {
            let plan = MentionQueryPlan.make(
                query: "TabStore.swift#res", scope: scope, isAbsolute: false, offersSymbols: true, displayLimit: 80)
            #expect(plan == MentionQueryPlan(
                sessions: false, symbols: .file(file: "TabStore.swift", symbol: "res"), fileQuery: nil))
        }
        // Files scope narrows by the file part; nothing to drill into without symbols.
        #expect(MentionQueryPlan.make(
            query: "TabStore.swift#res", scope: .files, isAbsolute: false, offersSymbols: true, displayLimit: 80
        ) == MentionQueryPlan(sessions: false, symbols: .none, fileQuery: "TabStore.swift"))
        #expect(MentionQueryPlan.make(
            query: "a#b", scope: .all, isAbsolute: false, offersSymbols: false, displayLimit: 80
        ) == MentionQueryPlan(sessions: true, symbols: .none, fileQuery: "a#b"))
    }

    @Test("project queries group by scope; All caps symbols and skips them for an empty query")
    func projectQueryPlans() {
        func plan(_ query: String, _ scope: MentionScope, absolute: Bool = false) -> MentionQueryPlan {
            MentionQueryPlan.make(query: query, scope: scope, isAbsolute: absolute, offersSymbols: true, displayLimit: 80)
        }
        #expect(plan("res", .all) == MentionQueryPlan(
            sessions: true, symbols: .project(query: "res", limit: MentionSymbolRanking.allScopeLimit), fileQuery: "res"))
        #expect(plan("", .all) == MentionQueryPlan(sessions: true, symbols: .none, fileQuery: ""))
        #expect(plan("", .symbols) == MentionQueryPlan(sessions: false, symbols: .project(query: "", limit: 80), fileQuery: nil))
        #expect(plan("res", .sessions) == MentionQueryPlan(sessions: true, symbols: .none, fileQuery: nil))
        #expect(plan("~/src#x", .all, absolute: true) == MentionQueryPlan(sessions: false, symbols: .none, fileQuery: "~/src#x"))
    }

    @Test("scopes offered follow the available sources; none when only files are")
    func offeredScopes() {
        #expect(MentionScope.offered(symbols: true, sessions: true) == [.all, .files, .symbols, .sessions])
        #expect(MentionScope.offered(symbols: false, sessions: true) == [.all, .files, .sessions])
        #expect(MentionScope.offered(symbols: true, sessions: false) == [.all, .files, .symbols])
        #expect(MentionScope.offered(symbols: false, sessions: false).isEmpty)
    }

    @Test("⇥ and ⇧⇥ cycle through the offered scopes, wrapping and skipping hidden ones", arguments: [
        (MentionScope.all, 1, MentionScope.offered(symbols: true, sessions: true), MentionScope.files),
        (.sessions, 1, MentionScope.offered(symbols: true, sessions: true), .all),
        (.all, -1, MentionScope.offered(symbols: true, sessions: true), .sessions),
        (.symbols, -1, MentionScope.offered(symbols: true, sessions: true), .files),
        (.files, 1, MentionScope.offered(symbols: false, sessions: true), .sessions),
        (.sessions, -1, MentionScope.offered(symbols: false, sessions: true), .files),
        (.symbols, 1, MentionScope.offered(symbols: true, sessions: false), .all),
        (.all, 1, MentionScope.offered(symbols: false, sessions: false), .all),
    ])
    func cyclesScopes(from: MentionScope, offset: Int, offered: [MentionScope], expected: MentionScope) {
        #expect(from.cycled(by: offset, in: offered) == expected)
    }

    @Test("the panel routes ↑ ↓ esc ⇥ ⇧⇥ ⏎ ⌥⏎ to the picker and leaves other keys to the field", arguments: [
        (UInt16(126), UInt(0), MentionPickerKey?.some(.up)),
        (125, NSEvent.ModifierFlags([.numericPad, .function]).rawValue, .down),
        (53, 0, .cancel),
        (48, 0, .nextScope),
        (48, NSEvent.ModifierFlags.shift.rawValue, .previousScope),
        (36, 0, .insert(includeCode: false)),
        (76, NSEvent.ModifierFlags.option.rawValue, .insert(includeCode: true)),
        (36, NSEvent.ModifierFlags.command.rawValue, nil),
        (126, NSEvent.ModifierFlags.shift.rawValue, nil),
        (0, 0, nil),
    ])
    func routesPickerKeys(keyCode: UInt16, modifiers: UInt, expected: MentionPickerKey?) {
        #expect(MentionPickerKey(keyCode: keyCode, modifiers: NSEvent.ModifierFlags(rawValue: modifiers)) == expected)
    }

    @Test("the panel opens below the caret, flips above without room, and stays on screen", arguments: [
        // Room below: top-left at the caret.
        (NSRect(x: 100, y: 600, width: 1, height: 16), NSPoint(x: 100, y: 160)),
        // No room below: flipped above the caret.
        (NSRect(x: 100, y: 200, width: 1, height: 16), NSPoint(x: 100, y: 216)),
        // Near the right edge: shifted left to fit.
        (NSRect(x: 900, y: 600, width: 1, height: 16), NSPoint(x: 440, y: 160)),
        // Room neither way: clamped to the visible frame.
        (NSRect(x: 100, y: 400, width: 1, height: 16), NSPoint(x: 100, y: 360)),
    ])
    func placesPanel(caret: NSRect, expected: NSPoint) {
        let visible = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let origin = PickerPanelPlacement.origin(size: NSSize(width: 560, height: 440), caret: caret, visibleFrame: visible)
        #expect(origin == expected)
    }

    // @MainActor: opens a real NSPanel; key window and first responder are
    // AppKit main-thread-only state.
    @Test("the search field takes focus when the panel opens with scope tabs")
    @MainActor func focusesSearchFieldOnOpen() async throws {
        let panel = ACPMentionPanel(
            worktreeRoot: URL(fileURLWithPath: "/tmp/project"),
            filesProvider: { [] },
            symbolMentions: ACPSymbolMentionSource(index: nil, fileSymbols: { _ in [] }),
            onPick: { _ in })
        defer { panel.close() }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(panel.firstResponder is NSTextView), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        // The field editor is first responder only while the field is edited.
        #expect(panel.firstResponder is NSTextView)
    }

    @Test("new results keep the highlighted item when it is still listed")
    func preservesHighlightedItem() {
        let a = MentionPickerItem.file(URL(fileURLWithPath: "/tmp/a"))
        let b = MentionPickerItem.file(URL(fileURLWithPath: "/tmp/b"))
        let s = MentionPickerItem.symbol(symbol("restore", .method))
        #expect(MentionPickerNavigation.index(preserving: b, fallback: 1, in: [s, a, b]) == 2)
        #expect(MentionPickerNavigation.index(preserving: b, fallback: 1, in: [s, a]) == 1)
        #expect(MentionPickerNavigation.index(preserving: nil, fallback: 5, in: [a]) == 0)
    }
}
