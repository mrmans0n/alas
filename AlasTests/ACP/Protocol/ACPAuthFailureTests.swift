import Foundation
import Testing
@testable import Alas

@Suite("ACPAuthFailure")
struct ACPAuthFailureTests {
    @Test("classifies auth-related JSON-RPC and runtime errors")
    func classifiesAuthRelatedErrors() {
        let cases: [(any Error, String)] = [
            (JSONRPCError(code: -32000, message: "auth_required", data: nil), "auth_required"),
            (JSONRPCError(code: -32000, message: "Internal error: auth required", data: nil), "auth required"),
            (ACPClientError.jsonrpc(JSONRPCError(
                code: -32000,
                message: "failed to authenticate with provider",
                data: nil
            )), "failed to authenticate with provider"),
            (NSError(
                domain: "ACP",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "invalid authentication credentials"]
            ), "invalid authentication credentials"),
            (NSError(
                domain: "ACP",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Internal error: 401 Unauthorized"]
            ), "401 Unauthorized")
        ]

        for (error, expected) in cases {
            #expect(ACPAuthFailure.message(from: error) == expected)
        }
    }

    @Test("ignores non-auth errors")
    func ignoresNonAuthErrors() {
        #expect(ACPAuthFailure.message(from: JSONRPCError(
            code: -32601,
            message: "Method not found",
            data: nil
        )) == nil)
        #expect(ACPAuthFailure.message(from: ACPClientError.noScript(method: "session/new")) == nil)
    }
}
