import Foundation

struct ACPFsWriteParams: Codable, Equatable {
    let sessionId: String
    let path: String
    let content: String
}

struct ACPFsReadParams: Codable, Equatable {
    let sessionId: String
    let path: String
    let line: Int?
    let limit: Int?
}

struct ACPFsReadResult: Codable, Equatable {
    let content: String
}

struct ACPFsWriteResult: Codable, Equatable {}
