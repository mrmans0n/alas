import Foundation

struct EditorDocumentID: Hashable, Sendable, Codable {
    let host: String?
    let worktreeID: String
    let uri: String
}

struct EditorRequestContext: Equatable, Sendable {
    let document: EditorDocumentID
    let version: Int
    let serverGeneration: UUID
    let range: LSPRange
    var sourceGeneration: Int? = nil
    var bindingID: UUID? = nil
    var bufferID: ObjectIdentifier? = nil
}
