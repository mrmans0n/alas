import Foundation

struct RemoteHelperHandshake: Codable, Equatable, Sendable {
    let name: String
    let protocolVersion: Int
    let binaryVersion: String

    var supportsExpectedContentWrite: Bool {
        let components = binaryVersion.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2,
              let major = Int(components[0]),
              let minor = Int(components[1])
        else { return false }
        return major > 0 || (major == 0 && minor >= 4)
    }

    static func decode(_ value: String) -> RemoteHelperHandshake? {
        guard let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RemoteHelperHandshake.self, from: data)
    }
}
