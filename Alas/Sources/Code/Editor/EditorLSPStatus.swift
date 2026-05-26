import Foundation

/// Bucketed LSP status surfaced to the editor breadcrumb badge. Derivation
/// from live manager / registry / availability state lives in
/// `EditorLSPStatusResolver`; this file is a pure value type.
enum EditorLSPStatus: Equatable {
    case ready(language: String, command: String)
    case loading(language: String)
    case problem(language: String, kind: ProblemKind, command: String?)
    case noLanguage(fileExtension: String)
}

enum ProblemKind: Equatable {
    case notInstalled
    case dead
    case disabled
}
