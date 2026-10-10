import Foundation
import Testing
@testable import Alas

struct RemoteMentionsTests {
    private let root = URL(fileURLWithPath: "/tmp/alas-remote-mentions/worktree")

    @Test(arguments: [
        (RemoteMention.file, "Alas/App.swift", "file:///tmp/alas-remote-mentions/worktree/Alas/App.swift"),
        (RemoteMention.file, "Alas/", "file:///tmp/alas-remote-mentions/worktree/Alas/"),
        (RemoteMention.file, "../secret", nil),
        (RemoteMention.file, "/etc/passwd", nil),
        (RemoteMention.file, ".git/config", nil),
        (RemoteMention.session, "other", "alas-session://other"),
        (RemoteMention.session, "self", nil),
        (RemoteMention.session, "foreign", nil),
        (RemoteMention.symbol, "alas-symbol://symbol?path=../x.swift&name=f&kind=function&start=0&end=1", nil),
        ("terminal", "anything", nil),
    ] as [(String, String, String?)])
    @MainActor
    func mentionsResolveOnlyInsideTheSessionsProject(kind: String, value: String, uri: String?) async {
        let attachment = await RemoteMentions.attachment(
            for: RemoteMention(kind: kind, value: value, name: "n"), worktreeRoot: root, sessionId: "self",
            isContainedFile: { RemoteWorktreeFileAccess.resolve(path: $0, in: root) != nil },
            isProjectSession: { $0 != "foreign" })
        #expect(attachment?.uri == uri)
    }

    @Test @MainActor func symbolMentionsAreReencodedFromTheParsedTarget() async throws {
        let target = ACPSymbolReference.Target(path: "App.swift", name: "run", kind: .function, container: "App",
                                               lineRange: 3...9, includeCode: false)
        let uri = ACPSymbolReference.uri(for: target) + "&extra=1"
        let attachment = try #require(await RemoteMentions.attachment(
            for: RemoteMention(kind: RemoteMention.symbol, value: uri, name: "App.run()"), worktreeRoot: root,
            sessionId: "self", isContainedFile: { _ in true }, isProjectSession: { _ in true }))
        #expect(attachment.uri == ACPSymbolReference.uri(for: target))
    }

    @Test func plainQueriesListSessionsThenFilesAndDrillDownsListOnlySymbols() {
        let session = ACPSessionMentionCandidate(id: "s2", projectId: "p", title: "App cleanup",
                                                 agentName: "Codex", worktreeName: "main")
        let symbol = SymbolEntry(name: "run", kind: .function, container: "App", languageID: "swift",
                                 relativePath: "Alas/App.swift", nameRange: NSRange(location: 0, length: 3),
                                 lineRange: 4...8)
        let plain = RemoteMentions.candidates(
            query: "app", root: root, filePaths: ["Alas/App.swift", "README.md"], sessions: [session],
            fileSymbols: [symbol])
        #expect(plain.map(\.kind) == [RemoteMention.session, RemoteMention.file])
        #expect(plain.last == RemoteMention(kind: RemoteMention.file, value: "Alas/App.swift", name: "App.swift",
                                            detail: "Alas"))

        let drill = RemoteMentions.candidates(
            query: "App.swift#ru", root: root, filePaths: ["Alas/App.swift"], sessions: [session],
            fileSymbols: [symbol])
        #expect(drill == [RemoteMentions.mention(symbol)])
        #expect(drill.first?.name == "App.run()")
    }
}
