import Foundation

/// Pure derivation from `(absolutePath, override?, worktreeRoot)` plus
/// injected probes to an `EditorLSPStatus`. No I/O, easy to unit-test by
/// passing fakes. The probes mirror the surface the resolver needs from
/// `WorkspaceLSPManager`, `LanguageServerAvailability`, and
/// `LanguageServerRegistry` so production code wires the real types and
/// tests wire fakes.
@MainActor
struct EditorLSPStatusResolver {
    protocol ManagerProbe {
        func documentStatus(forFile fileURL: URL, worktreeRoot: URL) -> WorkspaceLSPManager.DocumentStatus
    }

    protocol AvailabilityProbe {
        func status(forLanguage language: String) -> LanguageServerAvailability.Status?
        func command(forLanguage language: String) -> String?
    }

    protocol RegistryProbe {
        func language(forFileExtension ext: String) -> String?
    }

    let manager: ManagerProbe
    let availability: AvailabilityProbe
    let registry: RegistryProbe

    func resolve(absolutePath: String, override: String?, worktreeRoot: URL) -> EditorLSPStatus {
        let ext = LanguageServerRegistry.extensionKey(forPath: absolutePath)
        let inferred = registry.language(forFileExtension: ext)
        guard let language = override ?? inferred else {
            return .noLanguage(fileExtension: ext)
        }

        let command = availability.command(forLanguage: language)
        switch availability.status(forLanguage: language) {
        case .disabled:
            return .problem(language: language, kind: .disabled, command: command)
        case .notInstalled:
            return .problem(language: language, kind: .notInstalled, command: command)
        case .blockedByGatekeeper:
            // Surface as disabled — the dedicated Gatekeeper banner
            // (`BlockedNudgeBanner`) explains the actual root cause; the
            // breadcrumb badge only needs to communicate that the server
            // won't run.
            return .problem(language: language, kind: .disabled, command: command)
        case .available:
            let fileURL = URL(fileURLWithPath: absolutePath)
            switch manager.documentStatus(forFile: fileURL, worktreeRoot: worktreeRoot) {
            case .none, .loading:
                return .loading(language: language)
            case .ready:
                return .ready(language: language, command: command ?? "")
            case .dead:
                return .problem(language: language, kind: .dead, command: command)
            }
        case nil:
            // Language is mentioned somewhere (override) but the registry has
            // no entry for it. Treat as "no language server configured" → a
            // disabled-looking problem. Resolver tests don't currently
            // exercise this; the override picker only surfaces languages
            // that have a registry entry.
            return .problem(language: language, kind: .disabled, command: nil)
        }
    }
}
