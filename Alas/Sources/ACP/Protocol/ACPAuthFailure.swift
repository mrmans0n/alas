import Foundation

enum ACPAuthFailure {
    static func message(from error: any Error) -> String? {
        let message = normalizedMessage(from: error)
        let lowercased = message.lowercased()
        let markers = [
            "auth_required",
            "auth required",
            "failed to authenticate",
            "invalid authentication credentials",
            "unauthorized",
            "401"
        ]
        guard markers.contains(where: { lowercased.contains($0) }) else {
            return nil
        }
        return message
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
