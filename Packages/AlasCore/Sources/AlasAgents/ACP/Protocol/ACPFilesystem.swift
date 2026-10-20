import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

public struct ACPFsWriteParams: Codable, Equatable, Sendable {
    public let sessionId: String
    public let path: String
    public let content: String

    public init(sessionId: String, path: String, content: String) {
        self.sessionId = sessionId
        self.path = path
        self.content = content
    }
}

public struct ACPFsReadParams: Codable, Equatable, Sendable {
    public let sessionId: String
    public let path: String
    public let line: Int?
    public let limit: Int?

    public init(sessionId: String, path: String, line: Int?, limit: Int?) {
        self.sessionId = sessionId
        self.path = path
        self.line = line
        self.limit = limit
    }
}

public struct ACPFsReadResult: Codable, Equatable, Sendable {
    public let content: String

    public init(content: String) {
        self.content = content
    }
}

public struct ACPFsWriteResult: Codable, Equatable, Sendable {
    public init() {
    }}
