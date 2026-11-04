import Foundation
import AlasCode
import AlasFoundation

/// Selected v2 request contracts, independent of rendering and transport authority.
public struct ACPV2InteractiveRequest: Sendable {
    public struct Support: Equatable, Sendable {
        public let elicitation: Bool
        public let form: Bool
        public let url: Bool
        public init(elicitation: Bool = false, form: Bool = false, url: Bool = false) {
            self.elicitation = elicitation
            self.form = form
            self.url = url
        }
    }
    public struct Permission: Sendable {
        public struct Option: Sendable {
            public let optionID: String
            public let name: String
            public let kind: String
            public let rawValue: LSPJSONValue
        }
        public struct Subject: Sendable {
            public enum Kind: Sendable { case toolCall, command, unknown(String) }
            public let toolCallUpdate: ACPV2SessionUpdateEnvelope.ToolCallUpdate?
            public let kind: Kind
            public let rawValue: LSPJSONValue
        }
        public let sessionID: String
        public let title: String
        public let description: String?
        public let subject: Subject?
        public let options: [Option]
    }
    public struct Form: Sendable {
        public let sessionID: String
        public let message: String
        public let schema: LSPJSONValue
    }
    public struct URLRequest: Sendable {
        public let sessionID: String
        public let message: String
        public let elicitationID: String
        public let url: String
    }
    public enum Unsupported: Equatable, Sendable {
        case unknownMethod, unadvertisedMethod, unadvertisedMode, unknownMode, requestScope, wrongSession
    }
    public enum Classification: Sendable {
        case permission(Permission), form(Form), url(URLRequest)
        case cancelRequest(JSONRPCID), elicitationComplete(String)
        case unsupported(Unsupported), malformed(message: String)
    }
    public enum ProtocolError: Int, Sendable {
        case methodNotFound = -32601, invalidParams = -32602, requestCancelled = -32800
        var message: String {
            switch self {
            case .methodNotFound: "Method not found"
            case .invalidParams: "Invalid params"
            case .requestCancelled: "Request cancelled"
            }
        }
    }
    public enum Decision: Sendable {
        case selectPermission(optionID: String), cancelPermission
        case acceptElicitation(content: LSPJSONValue?), declineElicitation, cancelElicitation
        case reject(ProtocolError)
    }
    public enum DecisionError: Error, Equatable, Sendable {
        case invalidDecision, invalidAnswer(String), unsupportedValidation(String)
    }
    public typealias FormValidator = @MainActor (LSPJSONValue, LSPJSONValue?) -> ACPV2FormAnswerValidator.Result
    public let header: ACPV2InboundDelivery.Header
    public let classification: Classification
    public var rawValue: LSPJSONValue { header.rawValue }

    public static func decode(frame: Data, upstreamSessionId: String, support: Support) throws -> Self {
        let header = try ACPV2InboundDelivery.decodeHeader(from: frame)
        let classification: Classification
        do { classification = try classify(header, session: upstreamSessionId, support: support) }
        catch { classification = .malformed(message: String(describing: error)) }
        return .init(header: header, classification: classification)
    }

    private static func classify(_ header: ACPV2InboundDelivery.Header, session: String, support: Support) throws -> Classification {
        if header.method == "elicitation/create", !support.elicitation { return .unsupported(.unadvertisedMethod) }
        guard ["session/request_permission", "elicitation/create", "$/cancel_request", "elicitation/complete"].contains(header.method) else { return .unsupported(.unknownMethod) }
        let fields = try object(header.params)
        switch header.method {
        case "$/cancel_request":
            guard header.id == nil, let raw = fields["requestId"], let id = ACPRawRPCDelivery.stdioID(raw) else { throw DecisionError.invalidDecision }
            return .cancelRequest(id)
        case "elicitation/complete":
            guard header.id == nil else { throw DecisionError.invalidDecision }
            return .elicitationComplete(try string(fields, "elicitationId"))
        case "session/request_permission":
            guard header.id != nil else { throw DecisionError.invalidDecision }
            let sessionID = try string(fields, "sessionId")
            let title = try string(fields, "title")
            guard case .array(let rawOptions)? = fields["options"], !rawOptions.isEmpty else { throw DecisionError.invalidDecision }
            var keys = Set<Data>()
            let options = try rawOptions.map { raw -> Permission.Option in
                let option = try object(raw)
                let id = try string(option, "optionId")
                guard keys.insert(Data(id.utf8)).inserted else { throw DecisionError.invalidDecision }
                return .init(optionID: id, name: try string(option, "name"), kind: try string(option, "kind"), rawValue: raw)
            }
            var subject: Permission.Subject?
            if let raw = fields["subject"], raw != .null {
                let details = try object(raw)
                let type = try string(details, "type")
                let kind: Permission.Subject.Kind
                var patch: ACPV2SessionUpdateEnvelope.ToolCallUpdate?
                switch type {
                case "tool_call":
                    var tool = try object(details["toolCall"])
                    tool["sessionUpdate"] = .string("tool_call_update")
                    let event = try ACPV2SessionUpdateEnvelope(rawValue: .object(["sessionId": .string(sessionID), "update": .object(tool)]))
                    if case .toolCall(let value) = event.payload { patch = value }
                    kind = .toolCall
                case "command":
                    _ = try string(details, "command")
                    guard isAbsolute(try string(details, "cwd")) else { throw DecisionError.invalidDecision }
                    kind = .command
                default: kind = .unknown(type)
                }
                subject = .init(toolCallUpdate: patch, kind: kind, rawValue: raw)
            }
            guard sessionID.utf8.elementsEqual(session.utf8) else { return .unsupported(.wrongSession) }
            let description: String? = if case .string(let value)? = fields["description"] { value } else { nil }
            return .permission(.init(sessionID: sessionID, title: title, description: description, subject: subject, options: options))
        default:
            guard header.id != nil else { throw DecisionError.invalidDecision }
            let mode = try string(fields, "mode")
            let message = try string(fields, "message")
            let sessionScope = fields["sessionId"].flatMap { $0 == .null ? nil : $0 }
            let requestScope = fields["requestId"].flatMap { $0 == .null ? nil : $0 }
            guard (sessionScope != nil) != (requestScope != nil) else { throw DecisionError.invalidDecision }
            if let request = requestScope {
                guard ACPRawRPCDelivery.stdioID(request) != nil else { throw DecisionError.invalidDecision }
                return .unsupported(.requestScope)
            }
            let sessionID = try string(fields, "sessionId")
            guard sessionID.utf8.elementsEqual(session.utf8) else { return .unsupported(.wrongSession) }
            switch mode {
            case "form":
                guard support.form else { return .unsupported(.unadvertisedMode) }
                let schema = try object(fields["requestedSchema"])
                return .form(.init(sessionID: sessionID, message: message, schema: .object(schema)))
            case "url":
                guard support.url else { return .unsupported(.unadvertisedMode) }
                let id = try string(fields, "elicitationId"), url = try string(fields, "url")
                guard let components = URLComponents(string: url), components.scheme != nil,
                      !url.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || $0.value < 32 }) else { throw DecisionError.invalidDecision }
                return .url(.init(sessionID: sessionID, message: message, elicitationID: id, url: url))
            default: return .unsupported(.unknownMode)
            }
        }
    }

    @MainActor
    public func responseFrame(for decision: Decision, formValidator: FormValidator) throws -> Data {
        guard let id = header.id else { throw DecisionError.invalidDecision }
        let rawID: LSPJSONValue = switch id { case .string(let value): .string(value)
        case .number(let value): .number(String(value)) }
        var frame: [String: LSPJSONValue] = ["jsonrpc": .string("2.0"), "id": rawID]
        if case .reject(let error) = decision {
            switch classification {
            case .unsupported(.unknownMethod), .unsupported(.unadvertisedMethod): guard error == .methodNotFound else { throw DecisionError.invalidDecision }
            case .unsupported, .malformed: guard error == .invalidParams || error == .requestCancelled else { throw DecisionError.invalidDecision }
            case .permission, .form, .url: guard error == .requestCancelled || error == .invalidParams else { throw DecisionError.invalidDecision }
            default: throw DecisionError.invalidDecision
            }
            frame["error"] = .object(["code": .number(String(error.rawValue)), "message": .string(error.message)])
        } else {
            let result: LSPJSONValue
            switch (classification, decision) {
            case (.permission(let permission), .selectPermission(let selected)):
                guard permission.options.contains(where: { $0.optionID.utf8.elementsEqual(selected.utf8) }) else { throw DecisionError.invalidDecision }
                result = .object(["outcome": .object(["outcome": .string("selected"), "optionId": .string(selected)])])
            case (.permission, .cancelPermission): result = .object(["outcome": .object(["outcome": .string("cancelled")])])
            case (.form(let form), .acceptElicitation(let content)):
                if let content, content != .null { guard case .object = content else { throw DecisionError.invalidDecision } }
                switch formValidator(form.schema, content) {
                case .valid: break
                case .invalid(let message): throw DecisionError.invalidAnswer(message)
                case .unsupported(let message): throw DecisionError.unsupportedValidation(message)
                }
                var fields: [String: LSPJSONValue] = ["action": .string("accept")]
                fields["content"] = content
                result = .object(fields)
            case (.url, .acceptElicitation(let content)):
                guard content == nil || content == .null else { throw DecisionError.invalidDecision }
                result = .object(["action": .string("accept")])
            case (.form, .declineElicitation), (.url, .declineElicitation): result = .object(["action": .string("decline")])
            case (.form, .cancelElicitation), (.url, .cancelElicitation): result = .object(["action": .string("cancel")])
            default: throw DecisionError.invalidDecision
            }
            frame["result"] = result
        }
        let bytes = try LSPJSONValue.object(frame).encodedData()
        _ = try ACPRawReply.validateFrame(bytes)
        return bytes
    }

    private static func object(_ raw: LSPJSONValue?) throws -> [String: LSPJSONValue] {
        guard case .object(let fields)? = raw else { throw DecisionError.invalidDecision }
        return fields
    }
    private static func string(_ fields: [String: LSPJSONValue], _ key: String) throws -> String {
        guard case .string(let value)? = fields[key] else { throw DecisionError.invalidDecision }
        return value
    }
    private static func isAbsolute(_ path: String) -> Bool {
        let b = Array(path.utf8.prefix(3))
        return path.hasPrefix("/") || path.hasPrefix("\\\\") || (b.count == 3 && ((65...90).contains(b[0]) || (97...122).contains(b[0])) && b[1] == 58 && (b[2] == 47 || b[2] == 92))
    }
}
