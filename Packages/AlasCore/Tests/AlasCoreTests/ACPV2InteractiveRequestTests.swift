import Foundation
import Testing
import AlasCore

@MainActor
struct ACPV2InteractiveRequestTests {
    @Test(arguments: ["valid", "missing-title", "duplicate", "future", "relative", "unicode"])
    func permissionRequestsUseV2SubjectsAndExactOptions(variant: String) throws {
        var fields: [String: LSPJSONValue] = ["sessionId": .string("s"), "title": .string("Approve?"), "options": .array([Self.option("a")])]
        switch variant {
        case "missing-title": fields.removeValue(forKey: "title")
        case "duplicate": fields["options"] = .array([Self.option("a"), Self.option("a")])
        case "future": fields["subject"] = .object(["type": .string("_future"), "opaque": .number("1e999")])
        case "relative": fields["subject"] = .object(["type": .string("command"), "command": .string("tool"), "cwd": .string("relative")])
        case "unicode": fields["options"] = .array([Self.option("é"), Self.option("e\u{301}")])
        default: fields["subject"] = .null
        }
        let request = try Self.request("session/request_permission", params: .object(fields))
        if ["missing-title", "duplicate", "relative"].contains(variant) {
            guard case .malformed = request.classification else { Issue.record("Accepted malformed permission")
            return }
        } else {
            guard case .permission(let permission) = request.classification else { Issue.record("Missing permission")
            return }
            #expect(permission.title == "Approve?")
            if variant == "unicode" { #expect(permission.options.count == 2) }
            if variant == "future" { #expect(permission.subject?.rawValue == fields["subject"]) }
            let frame = try request.responseFrame(for: .selectPermission(optionID: variant == "unicode" ? "e\u{301}" : "a"), formValidator: ACPV2FormAnswerValidator.validate)
            #expect(try ACPRawReply.validateFrame(frame) == .string("original"))
            #expect(throws: (any Error).self) { try request.responseFrame(for: .selectPermission(optionID: "foreign"), formValidator: ACPV2FormAnswerValidator.validate) }
        }
    }

    @Test(arguments: ["/workspace", "C:/work", "C:\\work", "relative"])
    func commandSubjectsValidateNativeAbsolutePaths(cwd: String) throws {
        let request = try Self.request("session/request_permission", params: .object([
            "sessionId": .string("s"), "title": .string("Command"), "options": .array([Self.option("a")]),
            "subject": .object(["type": .string("command"), "command": .string("test"), "cwd": .string(cwd)]),
        ]))
        if cwd == "relative" { guard case .malformed = request.classification else { Issue.record("Accepted relative cwd")
        return } }
        else { guard case .permission = request.classification else { Issue.record("Rejected native absolute path")
        return } }
    }

    @Test(arguments: ["valid", "missing-mode", "both-scopes", "request", "future", "unadvertised", "mode-disabled", "session-null-other", "request-null-other", "both-null"])
    func elicitationModesScopesAndResponsesPreserveOpaqueJSON(variant: String) throws {
        var fields: [String: LSPJSONValue] = ["sessionId": .string("s"), "mode": .string("form"), "message": .string("Question"), "requestedSchema": .object(["type": .string("object")])]
        var support = ACPV2InteractiveRequest.Support(elicitation: true, form: true, url: true)
        switch variant {
        case "session-null-other": fields["requestId"] = .null
        case "request-null-other": fields["sessionId"] = .null
        fields["requestId"] = .number("3")
        case "both-null": fields["sessionId"] = .null
        fields["requestId"] = .null
        case "missing-mode": fields.removeValue(forKey: "mode")
        case "both-scopes": fields["requestId"] = .number("3")
        case "request": fields.removeValue(forKey: "sessionId")
        fields["requestId"] = .number("3")
        case "future": fields["mode"] = .string("_future")
        case "unadvertised": support = .init()
        case "mode-disabled": support = .init(elicitation: true)
        default: break
        }
        let request = try Self.request("elicitation/create", params: .object(fields), support: support)
        switch variant {
        case "missing-mode", "both-scopes", "both-null": guard case .malformed = request.classification else { Issue.record("Invalid scope/mode accepted")
        return }
        case "request", "request-null-other", "future", "unadvertised", "mode-disabled": guard case .unsupported = request.classification else { Issue.record("Unsupported elicitation offered")
        return }
        default:
            let content: LSPJSONValue = .object(["nested": .object(["n": .number("1e999"), "nil": .null]), "array": .array([.bool(true), .null])])
            let frame = try request.responseFrame(for: .acceptElicitation(content: content), formValidator: { _, _ in .valid })
            guard case .object(let envelope) = try LSPJSONValue.decode(from: frame), case .object(let result)? = envelope["result"] else { Issue.record("Missing result")
            return }
            #expect(result["content"] == content && result["action"] == .string("accept"))
        }
    }

    @Test(arguments: ["required", "optional-unknown", "custom-value", "enum-conflict", "scalar-length", "integer", "fraction", "pattern", "numeric-bound", "unknown-format", "array", "array-type", "array-bound", "duplicate-choice"])
    func defaultFormValidationNeverClaimsUnsupportedConstraints(variant: String) throws {
        var property: LSPJSONValue = .object(["type": .string("string")])
        var content: LSPJSONValue? = .object(["x": .string("ok")])
        var required: [LSPJSONValue] = [.string("x")]
        switch variant {
        case "array", "array-type", "array-bound":
            property = .object(["type": .string("array"), "items": .object(["type": .string(variant == "array-type" ? "number" : "string"),
                "anyOf": .array([.object(["const": .string("ok")])])]), "maxItems": .number("1")])
            content = .object(["x": .array(variant == "array-bound" ? [.string("ok"), .string("ok")] : [.string("ok")])])
        case "duplicate-choice": property = .object(["type": .string("string"), "enum": .array([.string("ok"), .string("ok")])])
        case "required": content = .object([:])
        case "optional-unknown": property = .object(["type": .string("_future")])
        required = []
        content = .object([:])
        case "custom-value": property = .object(["type": .string("_future")])
        content = .object(["x": .object(["n": .number("1e999")])])
        case "enum-conflict": property = .object(["type": .string("string"), "enum": .array([.string("ok")]), "oneOf": .array([])])
        case "scalar-length": property = .object(["type": .string("string"), "maxLength": .number("1")])
        content = .object(["x": .string("e\u{301}")])
        case "integer": property = .object(["type": .string("integer")])
        content = .object(["x": .number("1.0e999")])
        case "fraction": property = .object(["type": .string("integer")])
        content = .object(["x": .number("1e-999")])
        case "pattern": property = .object(["type": .string("string"), "pattern": .string("^a")])
        case "numeric-bound": property = .object(["type": .string("number"), "minimum": .number("1e999")])
        content = .object(["x": .number("1e999")])
        case "unknown-format": property = .object(["type": .string("string"), "format": .string("_future")])
        default: break
        }
        let result = ACPV2FormAnswerValidator.validate(schema: .object(["type": .string("object"), "properties": .object(["x": property]), "required": .array(required)]), content: content)
        if ["required", "scalar-length", "fraction", "array-bound"].contains(variant) { guard case .invalid = result else { Issue.record("Missing invalid value")
        return } }
        else if ["custom-value", "enum-conflict", "pattern", "numeric-bound", "array-type", "duplicate-choice"].contains(variant) { guard case .unsupported = result else { Issue.record("Unsupported constraint treated as valid")
        return } }
        else { #expect(result == .valid) }
    }

    @Test func notificationsAndUnsupportedRequestsCannotInventReplyAuthority() throws {
        let notification = try Self.request("$/cancel_request", params: .object(["requestId": .number("7")]), id: nil)
        guard case .cancelRequest(.number(7)) = notification.classification else { Issue.record("Missing directional cancel")
        return }
        #expect(throws: (any Error).self) { try notification.responseFrame(for: .reject(.requestCancelled), formValidator: ACPV2FormAnswerValidator.validate) }
        let unknown = try Self.request("_future", params: .null)
        let frame = try unknown.responseFrame(for: .reject(.methodNotFound), formValidator: ACPV2FormAnswerValidator.validate)
        guard case .object(let envelope) = try LSPJSONValue.decode(from: frame), case .object(let error)? = envelope["error"] else { Issue.record("Missing explicit error")
        return }
        #expect(error["code"] == .number("-32601"))
    }

    private static func option(_ id: String) -> LSPJSONValue { .object(["optionId": .string(id), "name": .string("Choice"), "kind": .string("_future")]) }
    private static func request(_ method: String, params: LSPJSONValue, support: ACPV2InteractiveRequest.Support = .init(), id: LSPJSONValue? = .string("original")) throws -> ACPV2InteractiveRequest {
        var raw: [String: LSPJSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method), "params": params]
        raw["id"] = id
        return try .decode(frame: LSPJSONValue.object(raw).encodedData(), upstreamSessionId: "s", support: support)
    }
}
