import Foundation

public struct EditorDocumentID: Hashable, Sendable, Codable {
    public let host: String?
    public let worktreeID: String
    public let uri: String

    public init(host: String?, worktreeID: String, uri: String) {
        self.host = host
        self.worktreeID = worktreeID
        self.uri = uri
    }
}

public struct EditorRequestContext: Equatable, Sendable {
    public let document: EditorDocumentID
    public let version: Int
    public let serverGeneration: UUID
    public let range: LSPRange
    public var sourceGeneration: Int? = nil
    public var bindingID: UUID? = nil
    public var bufferID: ObjectIdentifier? = nil

    public init(document: EditorDocumentID, version: Int, serverGeneration: UUID, range: LSPRange, sourceGeneration: Int? = nil, bindingID: UUID? = nil, bufferID: ObjectIdentifier? = nil) {
        self.document = document
        self.version = version
        self.serverGeneration = serverGeneration
        self.range = range
        self.sourceGeneration = sourceGeneration
        self.bindingID = bindingID
        self.bufferID = bufferID
    }
}
