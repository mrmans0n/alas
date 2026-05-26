import Foundation
import Testing
@testable import Alas

@Suite("BlockedLanguageServerNudgeResolver")
@MainActor
struct BlockedLanguageServerNudgeResolverTests {
    @Test("blocked LSP for the file's extension yields a nudge")
    func blockedYieldsNudge() {
        let resolver = BlockedLanguageServerNudgeResolver(
            registry: LanguageServerRegistry(userDefined: []),
            dismissedKeys: [],
            availabilityStatus: { entry in
                entry.language == "kotlin"
                    ? .blockedByGatekeeper(realPath: "/opt/homebrew/libexec/intellij-server")
                    : .available
            }
        )
        let nudge = resolver.nudgeData(forAbsolutePath: "/tmp/Main.kt")
        #expect(nudge?.language == "kotlin")
        #expect(nudge?.command == "kotlin-lsp")
        #expect(nudge?.realPath == "/opt/homebrew/libexec/intellij-server")
        #expect(nudge?.dismissalKey == "blocked:/opt/homebrew/libexec/intellij-server")
    }

    @Test("dismissed key suppresses the nudge")
    func dismissedSuppresses() {
        let resolver = BlockedLanguageServerNudgeResolver(
            registry: LanguageServerRegistry(userDefined: []),
            dismissedKeys: ["blocked:/opt/homebrew/libexec/intellij-server"],
            availabilityStatus: { _ in
                .blockedByGatekeeper(realPath: "/opt/homebrew/libexec/intellij-server")
            }
        )
        #expect(resolver.nudgeData(forAbsolutePath: "/tmp/Main.kt") == nil)
    }

    @Test("available LSP yields no nudge")
    func availableYieldsNone() {
        let resolver = BlockedLanguageServerNudgeResolver(
            registry: LanguageServerRegistry(userDefined: []),
            dismissedKeys: [],
            availabilityStatus: { _ in .available }
        )
        #expect(resolver.nudgeData(forAbsolutePath: "/tmp/Main.kt") == nil)
    }

    @Test("unknown extension yields no nudge")
    func unknownExtensionYieldsNone() {
        let resolver = BlockedLanguageServerNudgeResolver(
            registry: LanguageServerRegistry(userDefined: []),
            dismissedKeys: [],
            availabilityStatus: { _ in
                .blockedByGatekeeper(realPath: "/any")
            }
        )
        #expect(resolver.nudgeData(forAbsolutePath: "/tmp/Main.unknownext") == nil)
    }
}
