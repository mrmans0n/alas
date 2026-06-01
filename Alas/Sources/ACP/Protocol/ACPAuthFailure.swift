import Foundation

enum ACPAuthFailure {
    static func message(from error: any Error) -> String? {
        let message = normalizedMessage(from: error)
        let lowercased = message.lowercased()
        let markers = [
            "auth_required",
            "auth required",
            "authentication required",
            "failed to authenticate",
            "invalid authentication credentials",
            "not authenticated",
            "login required",
            "token expired",
            "expired token"
        ]
        guard markers.contains(where: { lowercased.contains($0) })
            || containsAuthStatus401(lowercased)
        else {
            return nil
        }
        return message
    }

    private static func containsAuthStatus401(_ message: String) -> Bool {
        guard message.contains("401") else { return false }
        let statusMarkers = [
            "http 401",
            "status 401",
            "401 unauthorized",
            "401 unauthorised",
            "401 auth",
            "401 authentication"
        ]
        return statusMarkers.contains { message.contains($0) }
    }

    private static func normalizedMessage(from error: any Error) -> String {
        let message: String
        switch error {
        case let error as JSONRPCError:
            message = error.message
        case ACPClientError.jsonrpc(let error):
            message = error.message
        case let error as any LocalizedError:
            message = error.errorDescription ?? error.localizedDescription
        default:
            message = error.localizedDescription
        }

        let prefix = "Internal error: "
        if message.hasPrefix(prefix) {
            return String(message.dropFirst(prefix.count))
        }
        return message
    }
}
