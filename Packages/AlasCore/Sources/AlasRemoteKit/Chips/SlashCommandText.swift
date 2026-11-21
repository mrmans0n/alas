import Foundation

/// Where known `/commands` sit in composer and message text. Commands are
/// matched by their exact name, `/` included.
public enum SlashCommandText {
    /// A known command at the very start of `text`, and what follows it.
    public static func match(in text: String, commands: [String]) -> (command: String, rest: Substring)? {
        guard text.hasPrefix("/") else { return nil }
        let token = text.prefix { !$0.isWhitespace }
        guard commands.contains(String(token)) else { return nil }
        var rest = text.dropFirst(token.count)
        // Only the single space that separates the command from its
        // argument (the same one the pill and the composer's own
        // hand-typed-command detection insert) is command syntax. A
        // newline right after the command is message structure — a blank
        // line, a new paragraph — and must stay in `rest` so multi-line
        // replies keep rendering below the pill instead of squeezed
        // beside it in the same row.
        if rest.first == " " {
            rest = rest.dropFirst()
        }
        return (String(token), rest)
    }

    /// Whether inserting a single whitespace character at `range` would
    /// complete a known command still typed as plain text — the hand-typed
    /// counterpart to picking one from the `/` menu. Intended to be checked
    /// BEFORE the whitespace reaches the text view, so the chip and the
    /// typed whitespace land in one edit instead of two.
    public static func chipTarget(
        completingWith insertedText: String,
        at range: NSRange,
        in string: String,
        commands: [String]
    ) -> (range: NSRange, command: String)? {
        guard range.length == 0,
              insertedText.count == 1,
              let scalar = insertedText.unicodeScalars.first,
              CharacterSet.whitespacesAndNewlines.contains(scalar)
        else { return nil }
        let string = string as NSString
        let end = range.location
        guard end <= string.length,
              end == string.length || isWhitespace(string.character(at: end))
        else { return nil }
        var start = end
        while start > 0, !isWhitespace(string.character(at: start - 1)) { start -= 1 }
        let tokenRange = NSRange(location: start, length: end - start)
        guard let command = knownCommand(in: string, at: tokenRange, commands: commands),
              !isInCode(start, in: string)
        else { return nil }
        return (tokenRange, command)
    }

    /// Whether `location` is inside code while the user is still typing
    /// there: a fenced block (closed or still open) or an inline code span,
    /// counting a backtick run still open at `location` as code — the same
    /// open-span rule as the upstream-reference keystroke path.
    public static func isInCode(_ location: Int, in string: NSString) -> Bool {
        // Through the character AT `location`, so a span left open before
        // it extends over it rather than ending exactly on it.
        let prefix = string.substring(to: min(location + 1, string.length)) as NSString
        return (codeRanges(in: string) + UpstreamReferenceText.codeRanges(in: prefix, unclosedRunsExtendToEnd: true))
            .contains { NSLocationInRange(location, $0) }
    }

    /// Fenced blocks as the composer's editor sees them (an unclosed fence
    /// runs to the end of the text) plus closed inline code spans.
    private static func codeRanges(in string: NSString) -> [NSRange] {
        MarkdownFenceEditing.blocks(in: string as String).map(\.outerRange)
            + UpstreamReferenceText.codeRanges(in: string, unclosedRunsExtendToEnd: false)
    }

    /// Ranges of known `/command` tokens that should become chips, in
    /// order. A token counts when it starts the text or follows whitespace,
    /// and only once whitespace follows it, so a command still being typed
    /// is left alone. Tokens inside code spans or fenced blocks stay text.
    public static func chipTargets(in string: String, commands: [String]) -> [(range: NSRange, command: String)] {
        guard !commands.isEmpty else { return [] }
        let string = string as NSString
        var targets: [(range: NSRange, command: String)] = []
        var index = 0
        while index < string.length {
            guard !isWhitespace(string.character(at: index)) else {
                index += 1
                continue
            }
            let start = index
            while index < string.length, !isWhitespace(string.character(at: index)) { index += 1 }
            let tokenRange = NSRange(location: start, length: index - start)
            if index < string.length,
               let command = knownCommand(in: string, at: tokenRange, commands: commands) {
                targets.append((tokenRange, command))
            }
        }
        guard !targets.isEmpty else { return [] }
        let code = codeRanges(in: string)
        return targets.filter { target in !code.contains { NSLocationInRange(target.range.location, $0) } }
    }

    /// The chip targets of `fragment`, about to replace `range` of `string`,
    /// in the fragment's own coordinates. The text on either side of `range`
    /// decides whether the fragment's edges are token boundaries and whether
    /// it lands inside code, so `/review` pasted right after `abc`, or
    /// between a code span's backticks, stays text.
    public static func chipTargets(
        inFragment fragment: String,
        replacing range: NSRange,
        in string: String,
        commands: [String]
    ) -> [(range: NSRange, command: String)] {
        let string = string as NSString
        let prefix = string.substring(to: range.location)
        let suffix = string.substring(from: NSMaxRange(range))
        let offset = (prefix as NSString).length
        let length = (fragment as NSString).length
        return chipTargets(in: prefix + fragment + suffix, commands: commands)
            .filter { $0.range.location >= offset && NSMaxRange($0.range) <= offset + length }
            .map { (NSRange(location: $0.range.location - offset, length: $0.range.length), $0.command) }
    }

    private static func knownCommand(in string: NSString, at tokenRange: NSRange, commands: [String]) -> String? {
        guard tokenRange.length > 1, string.character(at: tokenRange.location) == 0x2F else { return nil } // "/"
        let token = string.substring(with: tokenRange)
        return commands.contains(token) ? token : nil
    }

    private static func isWhitespace(_ character: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(character) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }
}
