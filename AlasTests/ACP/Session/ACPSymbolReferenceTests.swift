import Foundation
import Testing
@testable import Alas

@Suite("ACP symbol reference")
struct ACPSymbolReferenceTests {
    static let target = ACPSymbolReference.Target(
        path: "Sources/Session Manager/Ünïcode.swift", name: "restore", kind: .method,
        container: "SessionManager", lineRange: 119...157, includeCode: true
    )

    @Test("a target survives the URI round trip, including spaces and non-ASCII paths")
    func uriRoundTrip() {
        let uri = ACPSymbolReference.uri(for: Self.target)
        #expect(uri.hasPrefix("alas-symbol://"))
        #expect(ACPSymbolReference.target(fromURI: uri) == Self.target)
        #expect(Self.target.displayName == "SessionManager.restore()")
    }

    @Test("links that escape the worktree or are malformed are rejected", arguments: [
        "alas-symbol://symbol?path=../secret.swift&name=a&kind=method&start=0&end=0",
        "alas-symbol://symbol?path=/etc/passwd&name=a&kind=method&start=0&end=0",
        "alas-symbol://symbol?path=a/../../b.swift&name=a&kind=method&start=0&end=0",
        "alas-symbol://symbol?path=.git/hooks/a.swift&name=a&kind=method&start=0&end=0",
        "alas-symbol://symbol?path=sub/.GIT/a.swift&name=a&kind=method&start=0&end=0",
        "alas-symbol://symbol?path=a.swift&name=a&kind=nonsense&start=0&end=0",
        "alas-symbol://symbol?path=a.swift&name=a&kind=method&start=5&end=2",
        "alas-symbol://symbol?path=a.swift&name=a&kind=method&start=0&end=9223372036854775807",
        "alas-session://abc",
        "file:///tmp/a.swift",
    ])
    func rejectsUnsafeLinks(uri: String) {
        #expect(ACPSymbolReference.target(fromURI: uri) == nil)
    }

    private static let swiftSource = """
    struct SessionManager {
        init() {}
        init(id: String) {}
        func restore() {
            print("``` not a fence")
        }
    }
    """

    private func target(_ name: String, _ kind: SymbolKind, lines: ClosedRange<Int>, code: Bool = false) -> ACPSymbolReference.Target {
        .init(path: "Sources/SessionManager.swift", name: name, kind: kind,
              container: "SessionManager", lineRange: lines, includeCode: code)
    }

    @Test("resolution follows a moved declaration and picks the overload nearest the stored line")
    func resolvesMovedAndOverloaded() {
        let moved = "// header\n// header\n" + Self.swiftSource
        let restore = ACPSymbolReference.resolve(target("restore", .method, lines: 3...5), source: moved)
        #expect(restore.found)
        #expect(restore.lineRange == 5...7)
        #expect(restore.declaration?.hasPrefix("    func restore()") == true)

        let secondInit = ACPSymbolReference.resolve(target("init", .method, lines: 2...2), source: Self.swiftSource)
        #expect(secondInit.lineRange == 2...2)
        #expect(secondInit.declaration == "    init(id: String) {}")

        let gone = ACPSymbolReference.resolve(target("close", .method, lines: 9...9), source: Self.swiftSource)
        #expect(!gone.found)
        #expect(gone.lineRange == 9...9)
        #expect(ACPSymbolReference.resolve(target("restore", .method, lines: 3...5), source: nil).found == false)
    }

    @Test("excerpts stay within 400 lines and 32 KB, marker included, and say how much was cut", arguments: [
        (String(repeating: "x\n", count: 500), 400, 500, "… cut: showing 400 of 500 lines"),
        (String(repeating: String(repeating: "y", count: 1_000) + "\n", count: 50), 32, 50, "… cut: showing 32 of 50 lines"),
        (String(repeating: "z", count: 40_000), 1, 1, "… cut: showing 1 of 1 lines, first line shortened"),
        (String(repeating: "€", count: 12_000), 1, 1, "… cut: showing 1 of 1 lines, first line shortened"),
    ])
    func capsExcerpt(declaration: String, shown: Int, total: Int, marker: String) {
        let excerpt = ACPSymbolReference.excerpt(declaration)
        #expect(excerpt.truncated)
        #expect(excerpt.shownLines == shown)
        #expect(excerpt.totalLines == total)
        #expect(excerpt.text.utf8.count <= ACPSymbolReference.maxExcerptBytes)
        #expect(excerpt.text.hasSuffix(marker))
        #expect(!excerpt.text.contains("\u{FFFD}"), "cuts land on scalar boundaries, never mid-character")
        #expect(!ACPSymbolReference.excerpt("short\n").truncated)
    }

    @Test("the wire gets reference text, plus code as a resource or a fence that survives backticks")
    func replacesLinksOnTheWire() {
        let root = URL(fileURLWithPath: "/tmp/wt")
        let withCode = target("restore", .method, lines: 3...5, code: true)
        let withoutCode = target("restore", .method, lines: 3...5)
        let gone = target("close", .method, lines: 9...9, code: true)
        let sources = ["Sources/SessionManager.swift": Self.swiftSource]
        let blocks: [ACPContentBlock] = [
            .text("Why does @SessionManager.restore() fail? "),
            .resourceLink(uri: ACPSymbolReference.uri(for: withCode), name: "SessionManager.restore()"),
            .resourceLink(uri: ACPSymbolReference.uri(for: withoutCode), name: "SessionManager.restore()"),
            .resourceLink(uri: ACPSymbolReference.uri(for: gone), name: "SessionManager.close()"),
            .resourceLink(uri: "file:///tmp/wt/a.swift", name: "a.swift"),
            .resourceLink(uri: "ALAS-SYMBOL://symbol?path=../escape.swift&name=x&kind=function&start=0&end=0", name: "x()"),
        ]
        let reference = "Referenced symbol: SessionManager.restore(), method in Sources/SessionManager.swift, lines 4–6."

        let embedded = ACPSymbolReference.replacingReferences(in: blocks, with: ACPSymbolReference.expansion(
            of: blocks, sources: sources, worktreeRoot: root, embeddedContext: true))
        #expect(embedded[0] == blocks[0])
        #expect(embedded[1] == .text(reference))
        guard case .resource(let uri, _, let code) = embedded[2] else {
            Issue.record("expected resource, got \(embedded[2])")
            return
        }
        #expect(uri == "file:///tmp/wt/Sources/SessionManager.swift#L4-L6")
        #expect(code.hasPrefix("    func restore()"))
        #expect(embedded[3] == .text(reference))
        #expect(embedded[4] == .text("Referenced symbol: SessionManager.close(), method in Sources/SessionManager.swift, lines 10–10 (last known location; not found when sent)."))
        #expect(embedded[5] == blocks[4])
        #expect(embedded[6] == .text("Referenced symbol: x() (unreadable link; not sent)."))
        #expect(!embedded.contains { block in
            if case .resourceLink(let uri, _) = block { return uri.lowercased().hasPrefix("alas-symbol:") }
            return false
        }, "agents never see the alas-symbol scheme")

        let fenced = ACPSymbolReference.replacingReferences(in: blocks, with: ACPSymbolReference.expansion(
            of: blocks, sources: sources, worktreeRoot: root, embeddedContext: false))
        guard case .text(let text) = fenced[1] else {
            Issue.record("expected text, got \(fenced[1])")
            return
        }
        #expect(text.hasPrefix(reference + "\n\n````swift\n"))
        #expect(text.hasSuffix("\n````"))
        #expect(fenced.count == blocks.count)
    }

    @Test("recorded attachments carry the snapshot of what was sent")
    func attachesSnapshots() {
        let withCode = target("restore", .method, lines: 3...5, code: true)
        let uri = ACPSymbolReference.uri(for: withCode)
        let resolution = ACPSymbolReference.resolve(withCode, source: Self.swiftSource)
        let link = ACPContentBlock.resourceLink(uri: uri, name: "SessionManager.restore()")
        let attachments = ACPSymbolReference.attachingSnapshots(
            to: [.init(uri: uri, name: "SessionManager.restore()"), .init(uri: "file:///a", name: "a")],
            from: ACPSymbolReference.expansion(of: [link], sources: ["Sources/SessionManager.swift": Self.swiftSource],
                                               worktreeRoot: URL(fileURLWithPath: "/tmp/wt"), embeddedContext: true)
        )
        let snapshot = attachments[0].symbol
        #expect(snapshot?.found == true)
        #expect(snapshot?.lineRange == 3...5)
        #expect(snapshot?.excerpt == resolution.declaration)
        #expect(snapshot?.contentHash.count == 64)
        #expect(attachments[1].symbol == nil)
    }

    @Test("transcript links carry the sent range, falling back to the inserted one")
    func openURL() throws {
        let target = ACPSymbolReference.Target(path: "Package.swift", name: "a", kind: .function,
                                               container: nil, lineRange: 4...6, includeCode: true)
        let inserted = try #require(ACPSymbolReference.openURL(for: target, snapshot: nil))
        #expect(ACPSymbolReference.target(fromURI: inserted.absoluteString)?.lineRange == 4...6)
        let snapshot = ACPSymbolSnapshot(lineRange: 9...12, contentHash: "", excerpt: nil, truncated: false, found: true)
        let sent = try #require(ACPSymbolReference.openURL(for: target, snapshot: snapshot))
        #expect(ACPSymbolReference.target(fromURI: sent.absoluteString)?.lineRange == 9...12)
    }

    @Test("the hover preview numbers lines from the declaration's 1-based start")
    func hoverWindowNumbering() {
        let window = ACPSymbolHoverPreview.window(declaration: "func a() {\r\n    b()\r\n}", startLine: 98)
        #expect(window.text == "func a() {\n    b()\n}")
        #expect(window.firstLineNumber == 99)
        #expect(window.lineNumbers == "99\n100\n101")
        #expect(window.gutterDigits == 3)
        #expect(window.hiddenLines == 0)
    }

    @Test("the hover preview caps long declarations and long lines")
    func hoverWindowCaps() {
        let declaration = (0..<45).map { $0 == 0 ? String(repeating: "x", count: 12) : "line \($0)" }
            .joined(separator: "\n")
        let window = ACPSymbolHoverPreview.window(declaration: declaration, startLine: 0, maxLines: 40, maxColumns: 10)
        #expect(window.shownLines == 40)
        #expect(window.hiddenLines == 5)
        #expect(window.text.hasPrefix(String(repeating: "x", count: 10) + "…\nline 1\n"))
        #expect(window.text.hasSuffix("\nline 39"))
        #expect(window.lineNumbers.hasSuffix("\n40"))
    }

    // @MainActor: ACPSymbolHoverModel is main-actor UI state.
    @Test("the hover preview opens at the height the loaded code takes", arguments: [5, 100])
    @MainActor func hoverReservesLoadedHeight(lines: Int) {
        let target = ACPSymbolReference.Target(path: "a.swift", name: "a", kind: .function, container: nil,
                                               lineRange: 10...(9 + lines), includeCode: false)
        let model = ACPSymbolHoverModel(target: target, typography: .default)
        guard case .loading(let reserved) = model.state else {
            Issue.record("expected the loading state")
            return
        }
        let declaration = (0..<lines).map { "line \($0)" }.joined(separator: "\n")
        model.apply(.found(lineRange: target.lineRange,
                           window: ACPSymbolHoverPreview.window(declaration: declaration, startLine: 10)), theme: nil)
        guard case .found(let rendered) = model.state else {
            Issue.record("expected the found state")
            return
        }
        #expect(rendered.frame.codeHeight == reserved.codeHeight)
        #expect(rendered.frame.lineNumbers == reserved.lineNumbers)
        #expect(rendered.frame.hiddenLines == reserved.hiddenLines)
    }

    private static func hoverTarget(_ name: String, includeCode: Bool = false) -> ACPSymbolReference.Target {
        ACPSymbolReference.Target(path: "a.swift", name: name, kind: .function, container: nil,
                                  lineRange: 0...0, includeCode: includeCode)
    }

    private static func hoverFound(_ text: String) -> ACPSymbolHoverPreview.Loaded {
        .found(lineRange: 0...0, window: ACPSymbolHoverPreview.window(declaration: text, startLine: 0))
    }

    // @MainActor: ACPSymbolHoverCache is main-actor UI state.
    @Test("the hover cache evicts the least recently read preview, whichever badge reads it")
    @MainActor func hoverCacheEviction() {
        let cache = ACPSymbolHoverCache(capacity: 2)
        let root = URL(fileURLWithPath: "/tmp/project")
        cache.store(Self.hoverFound("a"), root: root, target: Self.hoverTarget("a"))
        cache.store(Self.hoverFound("b"), root: root, target: Self.hoverTarget("b"))
        #expect(cache.loaded(root: root, target: Self.hoverTarget("a", includeCode: true)) == Self.hoverFound("a"))
        cache.store(Self.hoverFound("c"), root: root, target: Self.hoverTarget("c"))
        #expect(cache.loaded(root: root, target: Self.hoverTarget("b")) == nil)
        #expect(cache.loaded(root: root, target: Self.hoverTarget("a")) == Self.hoverFound("a"))
        #expect(cache.loaded(root: root, target: Self.hoverTarget("c")) == Self.hoverFound("c"))
        #expect(cache.loaded(root: URL(fileURLWithPath: "/tmp/other"), target: Self.hoverTarget("c")) == nil)
    }

    // @MainActor: ACPSymbolHoverCache is main-actor UI state.
    @Test("a symbol that goes missing drops its cached hover preview")
    @MainActor func hoverCacheDropsMissing() {
        let cache = ACPSymbolHoverCache()
        let root = URL(fileURLWithPath: "/tmp/project")
        cache.store(Self.hoverFound("a"), root: root, target: Self.hoverTarget("a"))
        cache.store(.missing, root: root, target: Self.hoverTarget("a"))
        #expect(cache.loaded(root: root, target: Self.hoverTarget("a")) == nil)
    }
}
