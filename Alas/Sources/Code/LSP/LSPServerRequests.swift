import Foundation

struct LSPApplyEditResult: Sendable, Equatable {
    let applied: Bool
    var failureReason: String?
    var failedChange: Int?

    static let cancelled = LSPApplyEditResult(applied: false, failureReason: "The initiating editor or request was closed or cancelled.")

    var wireValue: LSPJSONValue {
        var fields: [String: LSPJSONValue] = ["applied": .bool(applied)]
        if let failureReason { fields["failureReason"] = .string(failureReason) }
        if let failedChange { fields["failedChange"] = .number(String(failedChange)) }
        return .object(fields)
    }
}

/// Each inbound request captures a handler. Its task runs independently of response consumption.
struct LSPServerRequests: Sendable {
    typealias EditHandler = @Sendable (LSPWorkspaceEdit) async -> LSPApplyEditResult
    typealias Configuration = @Sendable (String?, String?) async -> LSPJSONValue

    struct Reply: Sendable {
        var result: LSPJSONValue?
        var error: LSPResponseError?
    }

    var configuration: Configuration = { _, _ in .null }
    var applyEdit: EditHandler?

    func handle(method: String, params: LSPJSONValue) async -> Reply {
        switch method {
        case "workspace/configuration":
            guard case .array(let items) = params["items"] else { return invalidParams() }
            var values: [LSPJSONValue] = []
            for item in items {
                values.append(await configuration(item["scopeUri"]?.stringValue, item["section"]?.stringValue))
            }
            return Reply(result: .array(values))
        case "workspace/applyEdit":
            guard let value = params["edit"], let bytes = try? value.encodedData(),
                  let edit = try? JSONDecoder().decode(LSPWorkspaceEdit.self, from: bytes) else { return invalidParams() }
            guard !Task.isCancelled else { return Reply(result: LSPApplyEditResult.cancelled.wireValue) }
            guard let applyEdit else {
                return Reply(result: LSPApplyEditResult(applied: false, failureReason: "No active user command can accept this workspace edit.").wireValue)
            }
            let result = await applyEdit(edit)
            return Reply(result: (Task.isCancelled ? .cancelled : result).wireValue)
        default:
            // Dynamic registrations and refresh requests remain unsupported until consumers exist.
            return Reply(error: .init(code: -32601, message: "Method not implemented: \(method)"))
        }
    }

    private func invalidParams() -> Reply { Reply(error: .init(code: -32602, message: "Invalid request parameters")) }
}
