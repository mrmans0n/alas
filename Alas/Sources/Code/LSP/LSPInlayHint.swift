import Foundation

/// Preserve the wire payload, including numeric spelling in opaque server data.
struct LSPInlayHint: Sendable {
    struct Part: Sendable {
        let value: String
        let tooltip: LSPJSONValue?
        let location: LSPLocation?
        let command: LSPCommand?
    }

    let wireValue: LSPJSONValue
    let position: LSPPosition
    let parts: [Part]
    let kind: Int?
    let paddingLeft: Bool
    let paddingRight: Bool
    let tooltip: LSPJSONValue?
    let textEdits: [LSPTextEdit]?
    var label: String { parts.map(\.value).joined() }

    init(wireValue: LSPJSONValue) throws {
        func decode<T: Decodable>(_ value: LSPJSONValue?, as: T.Type) throws -> T? {
            guard let value, value != .null else { return nil }
            return try JSONDecoder().decode(T.self, from: value.encodedData())
        }
        guard let position = try decode(wireValue["position"], as: LSPPosition.self), position.line >= 0, position.character >= 0 else { throw LSPError.invalidPayload }
        self.position = position
        if let value = wireValue["label"]?.stringValue, !value.isEmpty {
            parts = [Part(value: value, tooltip: nil, location: nil, command: nil)]
        } else if case .array(let values) = wireValue["label"], !values.isEmpty {
            parts = try values.map { part in
                guard let value = part["value"]?.stringValue, !value.isEmpty else { throw LSPError.invalidPayload }
                return Part(value: value, tooltip: part["tooltip"], location: try decode(part["location"], as: LSPLocation.self), command: try part["command"].map(LSPCommand.init(wireValue:)))
            }
        } else { throw LSPError.invalidPayload }
        kind = try decode(wireValue["kind"], as: Int.self)
        paddingLeft = try decode(wireValue["paddingLeft"], as: Bool.self) ?? false
        paddingRight = try decode(wireValue["paddingRight"], as: Bool.self) ?? false
        tooltip = wireValue["tooltip"]
        textEdits = try decode(wireValue["textEdits"], as: [LSPTextEdit].self)
        self.wireValue = wireValue
    }

    func mergingResolved(_ resolved: LSPInlayHint) throws -> LSPInlayHint {
        guard position == resolved.position, parts.map(\.value) == resolved.parts.map(\.value),
              case .object(let original) = wireValue, case .object(let updates) = resolved.wireValue else { throw LSPError.invalidPayload }
        var merged = original.merging(updates) { _, new in new }
        if case .array(let originalParts) = original["label"], case .array(let updatedParts) = updates["label"] {
            merged["label"] = .array(zip(originalParts, updatedParts).map { originalPart, updatedPart in
                guard case .object(let originalFields) = originalPart, case .object(let updatedFields) = updatedPart else { return updatedPart }
                return .object(originalFields.merging(updatedFields) { _, new in new })
            })
        }
        return try LSPInlayHint(wireValue: .object(merged))
    }

    static func decodeList(_ data: Data?) throws -> [LSPInlayHint] {
        guard let data, data != Data("null".utf8) else { return [] }
        guard data.count <= JSONRPCFramer.maximumBodyBytes,
              case .array(let values) = try LSPJSONValue.decode(from: data), values.count <= 10000 else { throw LSPError.invalidPayload }
        return try values.map(LSPInlayHint.init(wireValue:))
    }

    static func tooltipText(_ value: LSPJSONValue?) -> String? {
        value?.stringValue ?? value?["value"]?.stringValue
    }
}
