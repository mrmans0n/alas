import Foundation

enum LocalTextSafety {
    static func containsCredential(_ text: String) -> Bool {
        if matches(text, #"(?i)-----BEGIN (?:[A-Z ]* )?PRIVATE KEY-----"#) { return true }
        if matches(text, #"\b(?:ghp_|gho_|ghu_|ghs_)[A-Za-z0-9]{36}\b|\bsk[-_](?:test[-_])?[A-Za-z0-9_-]{20,}\b"#) {
            return true
        }
        guard let regex = try? NSRegularExpression(
            pattern: #"(?i)\b(?:api[_-]?key|access[_-]?key|password|secret|token)\b\s*[:=]\s*([^\s;,]+)"#
        ) else { return false }
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let raw = ns.substring(with: match.range(at: 1))
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`."))
            let normalized = raw.lowercased()
            if ["[redacted]", "redacted", "placeholder", "example", "changeme",
                "<api_key>", "<access_key>", "<password>", "<secret>", "<token>",
                "your_api_key", "your_access_key", "your_password", "your_secret", "your_token"
            ].contains(normalized) { continue }
            return true
        }
        return false
    }

    static func containsActiveAction(
        _ text: String,
        pattern: String,
        includingQuotedCommands: Bool = false
    ) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if activeActionPrefix(
                ns.substring(to: match.range.location),
                includingQuotedCommands: includingQuotedCommands
            ) { return true }
        }
        return false
    }

    private static func activeActionPrefix(
        _ prefix: String,
        includingQuotedCommands: Bool
    ) -> Bool {
        let isQuoted = prefix.last == "'" || prefix.last == "\""
        if isQuoted && !includingQuotedCommands { return false }

        let actionablePrefix = isQuoted ? String(prefix.dropLast()) : prefix
        let near = String(actionablePrefix.suffix(35))
        if matches(near, #"(?i)\b(?:never|not|don.t|do\s+not|must\s+not|avoid)\s+(?:\w+\s+){0,2}$"#) {
            return false
        }
        return !isQuoted
            || near.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || matches(near, #"(?i)\b(?:run|execute)\s*$"#)
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}
