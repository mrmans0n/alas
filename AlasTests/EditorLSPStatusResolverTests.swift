import Testing
import Foundation
@testable import Alas

struct EditorPhaseCase: Sendable, CustomTestStringConvertible {
    let name: String
    let documentStatus: WorkspaceLSPManager.DocumentStatus
    let phase: LSPServerStatus.Phase
    let expected: EditorLSPStatus
    nonisolated var testDescription: String { name }
}

private let indexingTasks = [
    LSPClient.ProgressTask(token: "a", title: "Indexing", message: "40/100", percentage: 40),
    LSPClient.ProgressTask(token: "b", title: "Building", message: nil, percentage: 10),
]
private let crash = LSPServerStatus.CrashDetail(exitCode: 11, uptime: .seconds(3), outputTail: ["segfault"], initializeError: nil)

private let editorPhaseCases = [
    EditorPhaseCase(
        name: "ready holder still indexing reports the least-advanced percentage",
        documentStatus: .ready,
        phase: .indexing(indexingTasks),
        expected: .indexing(language: "swift", command: "sourcekit-lsp", percentage: 10, tasks: indexingTasks)
    ),
    EditorPhaseCase(
        name: "dead holder carries crash detail",
        documentStatus: .dead,
        phase: .crashed(crash),
        expected: .problem(language: "swift", kind: .dead(crash), command: "sourcekit-lsp")
    ),
]

@Suite("EditorLSPStatusResolver")
@MainActor
struct EditorLSPStatusResolverTests {
    struct FakeManager: EditorLSPStatusResolver.ManagerProbe {
        var status: WorkspaceLSPManager.DocumentStatus = .none
        var phase: LSPServerStatus.Phase? = nil
        func documentStatus(forFile fileURL: URL, worktreeRoot: URL) -> WorkspaceLSPManager.DocumentStatus {
            status
        }
        func serverPhase(forFile fileURL: URL, worktreeRoot: URL) -> LSPServerStatus.Phase? { phase }
    }

    struct FakeAvailability: EditorLSPStatusResolver.AvailabilityProbe {
        var statusByLanguage: [String: LanguageServerAvailability.Status]
        var commandByLanguage: [String: String]
        func status(forLanguage language: String) -> LanguageServerAvailability.Status? {
            statusByLanguage[language]
        }
        func command(forLanguage language: String) -> String? {
            commandByLanguage[language]
        }
    }

    struct FakeRegistry: EditorLSPStatusResolver.RegistryProbe {
        var languageByExt: [String: String]
        func language(forFileExtension ext: String) -> String? {
            languageByExt[ext]
        }
    }

    private func resolver(
        manager: FakeManager = .init(),
        availability: FakeAvailability = .init(statusByLanguage: [:], commandByLanguage: [:]),
        registry: FakeRegistry = .init(languageByExt: [:])
    ) -> EditorLSPStatusResolver {
        EditorLSPStatusResolver(manager: manager, availability: availability, registry: registry)
    }

    private let root = URL(fileURLWithPath: "/tmp/repo")
    private let swiftFile = URL(fileURLWithPath: "/tmp/repo/main.swift")

    @Test func noLanguageWhenExtensionUnknown() {
        let r = resolver()
        let result = r.resolve(absolutePath: "/tmp/repo/notes.xyz", override: nil, worktreeRoot: root)
        #expect(result == .noLanguage(fileExtension: "xyz"))
    }

    @Test func overrideWinsOverExtensionMatch() {
        let r = resolver(
            manager: FakeManager(status: .ready),
            availability: FakeAvailability(
                statusByLanguage: ["swift": .available, "typescript": .available],
                commandByLanguage: ["swift": "sourcekit-lsp", "typescript": "tsserver"]
            ),
            registry: FakeRegistry(languageByExt: ["swift": "swift"])
        )
        let result = r.resolve(absolutePath: swiftFile.path, override: "typescript", worktreeRoot: root)
        #expect(result == .ready(language: "typescript", command: "tsserver"))
    }

    @Test func problemDisabledWhenAvailabilityDisabled() {
        let r = resolver(
            availability: FakeAvailability(
                statusByLanguage: ["swift": .disabled],
                commandByLanguage: ["swift": "sourcekit-lsp"]
            ),
            registry: FakeRegistry(languageByExt: ["swift": "swift"])
        )
        let result = r.resolve(absolutePath: swiftFile.path, override: nil, worktreeRoot: root)
        #expect(result == .problem(language: "swift", kind: .disabled, command: "sourcekit-lsp"))
    }

    @Test func problemNotInstalledWhenAvailabilityNotInstalled() {
        let r = resolver(
            availability: FakeAvailability(
                statusByLanguage: ["swift": .notInstalled],
                commandByLanguage: ["swift": "sourcekit-lsp"]
            ),
            registry: FakeRegistry(languageByExt: ["swift": "swift"])
        )
        let result = r.resolve(absolutePath: swiftFile.path, override: nil, worktreeRoot: root)
        #expect(result == .problem(language: "swift", kind: .notInstalled, command: "sourcekit-lsp"))
    }

    @Test func loadingWhenNoHolderYet() {
        let r = resolver(
            manager: FakeManager(status: .none),
            availability: FakeAvailability(
                statusByLanguage: ["swift": .available],
                commandByLanguage: ["swift": "sourcekit-lsp"]
            ),
            registry: FakeRegistry(languageByExt: ["swift": "swift"])
        )
        let result = r.resolve(absolutePath: swiftFile.path, override: nil, worktreeRoot: root)
        #expect(result == .loading(language: "swift"))
    }

    @Test func loadingWhenHolderStillStarting() {
        let r = resolver(
            manager: FakeManager(status: .loading),
            availability: FakeAvailability(
                statusByLanguage: ["swift": .available],
                commandByLanguage: ["swift": "sourcekit-lsp"]
            ),
            registry: FakeRegistry(languageByExt: ["swift": "swift"])
        )
        let result = r.resolve(absolutePath: swiftFile.path, override: nil, worktreeRoot: root)
        #expect(result == .loading(language: "swift"))
    }

    @Test func readyWhenHolderReady() {
        let r = resolver(
            manager: FakeManager(status: .ready),
            availability: FakeAvailability(
                statusByLanguage: ["swift": .available],
                commandByLanguage: ["swift": "sourcekit-lsp"]
            ),
            registry: FakeRegistry(languageByExt: ["swift": "swift"])
        )
        let result = r.resolve(absolutePath: swiftFile.path, override: nil, worktreeRoot: root)
        #expect(result == .ready(language: "swift", command: "sourcekit-lsp"))
    }

    @Test func problemDeadWhenHolderDead() {
        let r = resolver(
            manager: FakeManager(status: .dead),
            availability: FakeAvailability(
                statusByLanguage: ["swift": .available],
                commandByLanguage: ["swift": "sourcekit-lsp"]
            ),
            registry: FakeRegistry(languageByExt: ["swift": "swift"])
        )
        let result = r.resolve(absolutePath: swiftFile.path, override: nil, worktreeRoot: root)
        #expect(result == .problem(language: "swift", kind: .dead(nil), command: "sourcekit-lsp"))
    }

    /// Regression guard for the `case nil` arm of the resolver. The override
    /// picker today only surfaces languages with a registry entry, so this
    /// branch isn't reachable from the badge UI — but the invariant lives in
    /// the picker, not the resolver, so this seeds the assertion in case a
    /// future caller (CLI, serialized tab state, tests) sets an override to
    /// an unregistered language.
    @Test func problemDisabledWhenAvailabilityReturnsNil() {
        let r = resolver(
            availability: FakeAvailability(statusByLanguage: [:], commandByLanguage: [:]),
            registry: FakeRegistry(languageByExt: [:])
        )
        let result = r.resolve(absolutePath: swiftFile.path, override: "unknown", worktreeRoot: root)
        #expect(result == .problem(language: "unknown", kind: .disabled, command: nil))
    }

    @Test("server phase refines ready and dead holders", arguments: editorPhaseCases)
    func serverPhaseRefinesStatus(_ testCase: EditorPhaseCase) {
        let r = resolver(
            manager: FakeManager(status: testCase.documentStatus, phase: testCase.phase),
            availability: FakeAvailability(
                statusByLanguage: ["swift": .available],
                commandByLanguage: ["swift": "sourcekit-lsp"]
            ),
            registry: FakeRegistry(languageByExt: ["swift": "swift"])
        )
        #expect(r.resolve(absolutePath: swiftFile.path, override: nil, worktreeRoot: root) == testCase.expected)
    }
}

@Suite("LSPBadgeState.make")
struct LSPBadgeStateMakeTests {
    @Test func startingPhaseOverridesTheTemporarilyDeadHolderOfARestart() {
        let state = LSPBadgeState.make(
            editor: .problem(language: "swift", kind: .dead(nil), command: "sourcekit-lsp"),
            phase: .starting
        )
        #expect(state == .starting(language: "swift"))
    }

    @Test func deadHolderWithCrashedPhaseStaysAProblem() {
        let state = LSPBadgeState.make(
            editor: .problem(language: "swift", kind: .dead(nil), command: "sourcekit-lsp"),
            phase: .crashed(crash)
        )
        #expect(state == .problem(language: "swift", reason: .crashed))
    }

    @Test func indexingPhaseRefinesAReadyHolder() {
        let state = LSPBadgeState.make(
            editor: .ready(language: "swift", command: "sourcekit-lsp"),
            phase: .indexing(indexingTasks)
        )
        #expect(state == .indexing(
            language: "swift",
            percentage: 10,
            tooltip: LSPProgressSummary.tooltip(command: "sourcekit-lsp", tasks: indexingTasks)
        ))
    }
}
