import Foundation

/// Bucketed LSP status surfaced to the editor breadcrumb badge. Derivation
/// from live manager / registry / availability state lives in
/// `EditorLSPStatusResolver`; this file is a pure value type.
enum EditorLSPStatus: Equatable, Sendable {
    case ready(language: String, command: String)
    case loading(language: String)
    case indexing(language: String, command: String, percentage: Int?, tasks: [LSPClient.ProgressTask])
    case problem(language: String, kind: ProblemKind, command: String?)
    case noLanguage(fileExtension: String)
}

enum ProblemKind: Equatable, Sendable {
    case notInstalled
    case dead(LSPServerStatus.CrashDetail?)
    case disabled
}

extension EditorLSPStatus {
    /// Language id for this status, if any. `.noLanguage` returns nil.
    var language: String? {
        switch self {
        case .ready(let lang, _), .loading(let lang), .indexing(let lang, _, _, _), .problem(let lang, _, _):
            return lang
        case .noLanguage: return nil
        }
    }

    var badgeState: LSPBadgeState {
        switch self {
        case .ready(let language, let command):
            .ready(language: language, command: command)
        case .loading(let language):
            .starting(language: language)
        case .indexing(let language, let command, let percentage, let tasks):
            .indexing(language: language, percentage: percentage, tooltip: LSPProgressSummary.tooltip(command: command, tasks: tasks))
        case .problem(let language, .notInstalled, _):
            .problem(language: language, reason: .notInstalled)
        case .problem(let language, .dead, _):
            .problem(language: language, reason: .crashed)
        case .problem(let language, .disabled, _):
            .problem(language: language, reason: .disabled)
        case .noLanguage(let ext):
            .noLanguage(fileExtension: ext)
        }
    }
}
