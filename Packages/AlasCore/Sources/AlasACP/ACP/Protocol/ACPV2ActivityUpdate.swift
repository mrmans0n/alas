import Foundation
import AlasCode

extension ACPV2SessionUpdateEnvelope {
    public enum ValuePatch<Value: Equatable & Sendable>: Equatable, Sendable {
        case omitted, clear
        case value(Value)

        func applying(to current: Value?) -> Value? {
            switch self {
            case .omitted: current
            case .clear: nil
            case .value(let value): value
            }
        }

        func applying(to current: Value, cleared: Value) -> Value {
            switch self {
            case .omitted: current
            case .clear: cleared
            case .value(let value): value
            }
        }
    }

    public struct ToolContent: Equatable, Sendable {
        public let rawValue: LSPJSONValue
        public let terminalID: String?
    }

    public struct ToolCallUpdate: Equatable, Sendable {
        public let toolCallID: String
        public let name: ValuePatch<String>
        public let title: ValuePatch<String>
        public let kind: ValuePatch<String>
        public let status: ValuePatch<String>
        public let content: ValuePatch<[ToolContent]>
        public let locations: ValuePatch<[LSPJSONValue]>
        public let rawInput: ValuePatch<LSPJSONValue>
        public let rawOutput: ValuePatch<LSPJSONValue>
        public let metadata: MetadataPatch
    }

    public struct ToolContentChunk: Equatable, Sendable {
        public let toolCallID: String
        public let content: ToolContent
    }

    public struct PlanUpdate: Equatable, Sendable {
        public let planID: String
        public let type: String
        /// Nil is opaque future content; an empty array is a known empty items plan.
        public let entries: [LSPJSONValue]?
        public let rawValue: LSPJSONValue
    }

    public struct OutputSnapshot: Equatable, Sendable {
        public let data: Data
        public let metadata: [String: LSPJSONValue]?
        public let rawValue: LSPJSONValue
    }

    public struct ExitInformation: Equatable, Sendable {
        public let exitCode: UInt32?
        public let signal: String?
        public let metadata: [String: LSPJSONValue]?
        public let rawValue: LSPJSONValue
    }

    public struct TerminalUpdate: Equatable, Sendable {
        public let terminalID: String
        public let command: ValuePatch<String>
        public let cwd: ValuePatch<String>
        public let output: ValuePatch<OutputSnapshot>
        public let exitStatus: ValuePatch<ExitInformation>
        public let metadata: MetadataPatch
    }

    public struct TerminalOutputChunk: Equatable, Sendable {
        public let terminalID: String
        public let data: Data
    }

    static func activity(_ fields: [String: LSPJSONValue], variant: String) throws -> Payload {
        switch variant {
        case "tool_call_update", "tool_call_content_chunk", "plan_update", "terminal_update", "terminal_output_chunk": break
        default: return .unhandled
        }
        let meta = try metadata(fields["_meta"])
        switch variant {
        case "tool_call_update":
            return .toolCall(ToolCallUpdate(
                toolCallID: try requiredString(fields, "toolCallId"),
                name: try stringPatch(fields, "name"), title: try stringPatch(fields, "title"),
                kind: try stringPatch(fields, "kind"), status: try stringPatch(fields, "status"),
                content: try patch(fields, "content") { try array($0).map(toolContent) },
                locations: try patch(fields, "locations") { try array($0).map(location) },
                rawInput: try patch(fields, "rawInput") { $0 },
                rawOutput: try patch(fields, "rawOutput") { $0 }, metadata: meta))
        case "tool_call_content_chunk":
            guard let content = fields["content"] else { throw invalid("tool content is required") }
            return .toolContentChunk(ToolContentChunk(toolCallID: try requiredString(fields, "toolCallId"),
                content: try toolContent(content)))
        case "plan_update":
            guard let plan = fields["plan"] else { throw invalid("plan is required") }
            return .plan(try planValue(plan))
        case "terminal_update":
            return .terminal(TerminalUpdate(terminalID: try requiredString(fields, "terminalId"),
                command: try stringPatch(fields, "command"), cwd: try stringPatch(fields, "cwd"),
                output: try patch(fields, "output", parse: outputSnapshot),
                exitStatus: try patch(fields, "exitStatus", parse: exitInformation), metadata: meta))
        case "terminal_output_chunk":
            return .terminalOutputChunk(TerminalOutputChunk(terminalID: try requiredString(fields, "terminalId"),
                data: try base64(requiredString(fields, "data"))))
        default: return .unhandled
        }
    }

    private static func toolContent(_ raw: LSPJSONValue) throws -> ToolContent {
        let fields = try object(raw)
        let type = try requiredString(fields, "type")
        _ = try metadata(fields["_meta"])
        return ToolContent(rawValue: raw, terminalID: type == "terminal" ? try requiredString(fields, "terminalId") : nil)
    }

    private static func location(_ raw: LSPJSONValue) throws -> LSPJSONValue {
        let fields = try object(raw)
        _ = try requiredString(fields, "path")
        _ = try patch(fields, "line", parse: uint32)
        _ = try metadata(fields["_meta"])
        return raw
    }

    private static func planValue(_ raw: LSPJSONValue) throws -> PlanUpdate {
        let fields = try object(raw)
        let type = try requiredString(fields, "type")
        let id = try requiredString(fields, "planId")
        _ = try metadata(fields["_meta"])
        var entries: [LSPJSONValue]?
        if type == "items" {
            guard let value = fields["entries"] else { throw invalid("plan entries are required") }
            entries = try array(value)
            for entry in entries ?? [] {
                let item = try object(entry)
                for key in ["content", "priority", "status"] { _ = try requiredString(item, key) }
                _ = try metadata(item["_meta"])
            }
        }
        return PlanUpdate(planID: id, type: type, entries: entries, rawValue: raw)
    }

    private static func outputSnapshot(_ raw: LSPJSONValue) throws -> OutputSnapshot {
        let fields = try object(raw)
        return OutputSnapshot(data: try base64(requiredString(fields, "data")),
            metadata: try scopedMetadata(fields["_meta"]), rawValue: raw)
    }

    private static func exitInformation(_ raw: LSPJSONValue) throws -> ExitInformation {
        let fields = try object(raw)
        return ExitInformation(exitCode: try patch(fields, "exitCode", parse: uint32).applying(to: nil),
            signal: try stringPatch(fields, "signal").applying(to: nil),
            metadata: try scopedMetadata(fields["_meta"]), rawValue: raw)
    }

    private static func scopedMetadata(_ raw: LSPJSONValue?) throws -> [String: LSPJSONValue]? {
        if case .patch(let fields) = try metadata(raw) { return fields }
        return nil
    }

    private static func patch<Value>(_ fields: [String: LSPJSONValue], _ key: String,
        parse: (LSPJSONValue) throws -> Value) throws -> ValuePatch<Value> {
        guard let raw = fields[key] else { return .omitted }
        if raw == .null { return .clear }
        return .value(try parse(raw))
    }

    private static func stringPatch(_ fields: [String: LSPJSONValue], _ key: String) throws -> ValuePatch<String> {
        try patch(fields, key) { value in
            guard case .string(let string) = value else { throw invalid("\(key) must be a string or null") }
            return string
        }
    }

    private static func requiredString(_ fields: [String: LSPJSONValue], _ key: String) throws -> String {
        guard case .string(let value)? = fields[key] else { throw invalid("\(key) must be a string") }
        return value
    }

    private static func object(_ value: LSPJSONValue) throws -> [String: LSPJSONValue] {
        guard case .object(let fields) = value else { throw invalid("expected an object") }
        return fields
    }

    private static func array(_ value: LSPJSONValue) throws -> [LSPJSONValue] {
        guard case .array(let items) = value else { throw invalid("expected an array") }
        return items
    }

    private static func base64(_ string: String) throws -> Data {
        guard let data = Data(base64Encoded: string), data.base64EncodedString() == string else {
            throw invalid("expected canonical RFC 4648 base64")
        }
        return data
    }

    private static func uint32(_ value: LSPJSONValue) throws -> UInt32 {
        guard let result = ACPWireInteger.decode(value, as: UInt32.self) else {
            throw invalid("expected an exact uint32 number")
        }
        return result
    }
}

extension ACPV2SessionUpdateEnvelope.MetadataPatch {
    func applying(to original: [String: LSPJSONValue]) -> [String: LSPJSONValue] {
        switch self {
        case .unchanged: return original
        case .clear: return [:]
        case .patch(let fields):
            var result = original
            for (key, value) in fields {
                if value == .null { result.removeValue(forKey: key) }
                else { result[key] = value }
            }
            return result
        }
    }
}
