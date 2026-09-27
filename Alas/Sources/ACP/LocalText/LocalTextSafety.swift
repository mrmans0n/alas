import Foundation

enum LocalTextSafety {
    private static let privateKeyHeaderPattern = #"(?i)-----BEGIN (?:[A-Z ]* )?PRIVATE KEY-----"#
    private static let tokenPattern = #"\b(?:ghp_|gho_|ghu_|ghs_)[A-Za-z0-9]{36}\b|\bsk[-_](?:test[-_])?[A-Za-z0-9_-]{20,}\b"#
    private static let assignmentRegex = try! NSRegularExpression(
        pattern: #"(?i)\b(?:api[_-]?key|access[_-]?key|password|secret|token)\b\s*[:=]\s*([^\s;,]+)"#
    )
    private static let assignmentRedactionRegex = try! NSRegularExpression(
        pattern: #"(?i)\b(api[_-]?key|access[_-]?key|password|secret|token)\b\s*([:=])\s*([^\s;,]+)"#
    )
    private static let placeholderValues: Set<String> = [
        "[redacted]", "redacted", "placeholder", "example", "changeme",
        "<api_key>", "<access_key>", "<password>", "<secret>", "<token>",
        "your_api_key", "your_access_key", "your_password", "your_secret", "your_token",
    ]

    static func containsCredential(_ text: String) -> Bool {
        if matches(text, privateKeyHeaderPattern) || matches(text, tokenPattern) { return true }
        let ns = text as NSString
        for match in assignmentRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let raw = ns.substring(with: match.range(at: 1))
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`."))
            if placeholderValues.contains(raw.lowercased()) { continue }
            return true
        }
        return false
    }

    /// Single-line masking; callers that see whole logs handle multi-line PEM blocks.
    static func redactingCredentials(_ text: String) -> String {
        let masked = text
            .replacingOccurrences(of: privateKeyHeaderPattern + ".*", with: "[redacted private key]", options: .regularExpression)
            .replacingOccurrences(of: tokenPattern, with: "[redacted]", options: .regularExpression)
        let mutable = NSMutableString(string: masked)
        let matches = assignmentRedactionRegex.matches(in: masked, range: NSRange(location: 0, length: mutable.length))
        for match in matches.reversed() {
            let key = mutable.substring(with: match.range(at: 1))
            let separator = mutable.substring(with: match.range(at: 2))
            let value = mutable.substring(with: match.range(at: 3))
            guard isSecretValue(value, key: key, separator: separator) else { continue }
            mutable.replaceCharacters(in: match.range(at: 3), with: "[redacted]")
        }
        return mutable as String
    }

    /// Parsers print `token: <word>` ("Unexpected token: punc"), so only that key
    /// needs a generated-looking value before its colon form counts as a secret.
    private static func isSecretValue(_ value: String, key: String, separator: String) -> Bool {
        let bare = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`."))
        if placeholderValues.contains(bare.lowercased()) { return false }
        if separator == "=" || key.lowercased() != "token" { return true }
        return bare.count >= 8 && bare.contains(where: \.isNumber)
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
            || !matches(near, #"(?i)\b(?:explain|describe|discuss)\s+(?:why|how)\s*$"#)
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}
