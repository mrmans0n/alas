import Foundation
import AlasFoundation
import AlasModel

public struct RemoteHelperHandshake: Codable, Equatable, Sendable {
    public let name: String
    public let protocolVersion: Int
    public let binaryVersion: String

    public var supportsFilesystemV04Contract: Bool {
        let components = binaryVersion.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2,
              let major = Int(components[0]),
              let minor = Int(components[1])
        else { return false }
        return major > 0 || (major == 0 && minor >= 4)
    }

    public var supportsExpectedContentWrite: Bool {
        supportsFilesystemV04Contract
    }

    public static func decode(_ value: String) -> RemoteHelperHandshake? {
        guard let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RemoteHelperHandshake.self, from: data)
    }

    public init(name: String, protocolVersion: Int, binaryVersion: String) {
        self.name = name
        self.protocolVersion = protocolVersion
        self.binaryVersion = binaryVersion
    }
}
