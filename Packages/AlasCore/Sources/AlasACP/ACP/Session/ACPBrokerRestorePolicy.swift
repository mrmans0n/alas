import Foundation
import AlasPlatform

public struct ACPBrokerRestoreDescriptor: Equatable, Sendable {
    public let brokerId: ACPBrokerID
    public let generation: ACPBrokerGeneration?
    public let acknowledgedCursor: ACPBrokerEventCursor
    public let wireContext: ACPBrokerWireContext
}

public enum ACPBrokerRestoreError: LocalizedError, Equatable, Sendable {
    case malformedContext(String)
    case invalidDescriptor(contextJSON: String?)
    case unsupported(context: ACPBrokerWireContext, storedJSON: String?)

    public var errorDescription: String? {
        switch self {
        case .malformedContext:
            "This saved broker has an unrecognized ACP context. Its broker and history were preserved."
        case .invalidDescriptor:
            "This saved broker has an invalid connection descriptor. Its broker and history were preserved."
        case .unsupported:
            "This saved connection needs ACP 2 runner support. Its broker, queued prompts and history were preserved."
        }
    }
}

extension ACPBrokerWireContext {
    public func persistedJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

public enum ACPBrokerRestorePolicy {
    public static func context(from storedJSON: String?) throws -> ACPBrokerWireContext {
        guard let storedJSON else { return .legacyV1 }
        do { return try JSONDecoder().decode(ACPBrokerWireContext.self, from: Data(storedJSON.utf8)) }
        catch { throw ACPBrokerRestoreError.malformedContext(storedJSON) }
    }

    public static func resolve(row: ACPSessionRow?, supportedVersions: Set<ACPProtocolVersion>) throws -> ACPBrokerRestoreDescriptor? {
        guard let row else { return nil }
        let raw = row.acpBrokerWireContextJSON
        let context = try context(from: raw)
        guard let id = row.acpBrokerId else {
            guard row.acpBrokerGeneration == nil, raw == nil, row.acpBrokerAcknowledgedCursor == 0 else {
                throw ACPBrokerRestoreError.invalidDescriptor(contextJSON: raw)
            }
            return nil
        }
        let validID = !id.isEmpty && id.utf8.count <= 160 && id.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
        guard validID, row.acpBrokerAcknowledgedCursor >= 0,
              row.acpBrokerGeneration.map({ $0 > 0 }) ?? (context == .legacyV1 && row.acpBrokerAcknowledgedCursor == 0) else {
            throw ACPBrokerRestoreError.invalidDescriptor(contextJSON: raw)
        }
        let version: ACPProtocolVersion = context == .rawV2 ? .v2 : .v1
        guard supportedVersions.contains(version) else {
            throw ACPBrokerRestoreError.unsupported(context: context, storedJSON: raw)
        }
        return ACPBrokerRestoreDescriptor(brokerId: .init(rawValue: id),
            generation: row.acpBrokerGeneration.map { .init(rawValue: UInt64($0)) },
            acknowledgedCursor: .init(rawValue: UInt64(row.acpBrokerAcknowledgedCursor)), wireContext: context)
    }
}
