import Foundation

struct RemoteHelperHandshake: Codable, Equatable, Sendable {
    let name: String
    let protocolVersion: Int
    let binaryVersion: String

    static func decode(_ value: String) -> RemoteHelperHandshake? {
        guard let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RemoteHelperHandshake.self, from: data)
    }
}
