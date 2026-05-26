import Testing
import Foundation
@testable import Alas

@MainActor
@Suite("EditorLSPStatusResolver")
struct EditorLSPStatusResolverTests {
    struct FakeManager: EditorLSPStatusResolver.ManagerProbe {
        var status: WorkspaceLSPManager.DocumentStatus = .none
        func documentStatus(forFile fileURL: URL, worktreeRoot: URL) -> WorkspaceLSPManager.DocumentStatus {
            status
        }
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
        #expect(result == .problem(language: "swift", kind: .dead, command: "sourcekit-lsp"))
    }
}
